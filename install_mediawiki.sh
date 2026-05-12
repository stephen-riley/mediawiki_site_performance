#!/bin/bash
# Exit script if any command fails
set -e

CONFIG_FILE="./config.sh"

# Check if the config file exists
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading configuration from $CONFIG_FILE..."
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found."
    exit 1
fi

# ==============================================================================

echo "Starting MediaWiki Stack Installation with PHP 8.4..."

# Helps with badly configured IPv6
echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4

# Update the system and add the PHP repository
# apt update && apt upgrade -y
apt install -y software-properties-common ca-certificates lsb-release apt-transport-https

# Add Ondřej Surý PHP PPA
add-apt-repository ppa:ondrej/php -y
apt update

# Install Apache, MariaDB, Memcached, and PHP 8.4 FPM with required extensions
apt install -y apache2 mariadb-server imagemagick \
    php8.4-fpm php8.4-mysql php8.4-xml php8.4-mbstring \
    php8.4-intl php8.4-apcu curl wget unzip redis php8.4-redis \
    php-curl python-is-python3

# Set up the cloudflared tunnel
curl -L https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
apt update
apt install cloudflared

# Configure MariaDB with larger buffer pool
cat <<EOF > /etc/mysql/mariadb.conf.d/99-override-buffer-pool-size.cnf
[mariadb]
# Set the buffer pool to 3GB
innodb_buffer_pool_size = 3G

# Optional: Increase the log file size to match a larger pool
# (This helps with write performance)
innodb_log_file_size = 512M
EOF

systemctl start mariadb
systemctl enable mariadb

# Create the database and user
mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE ${DB_NAME};
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# This allows you to just use `mysql` in the CLI and not have to specify credentials
cat <<EOF > /home/${CLI_USER}/.my.cnf
[client]
host = 127.0.0.1
database = "${DB_NAME}"
user = ${DB_USER}
password = "${DB_PASS}"
EOF

# Set up redis with 1GB of memory and LRU eviction strategy
echo "" | sudo tee -a /etc/redis/redis.conf
echo "# --- MEDIAWIKI CUSTOM REDIS LIMITS ---" | sudo tee -a /etc/redis/redis.conf
echo "maxmemory 1gb" | sudo tee -a /etc/redis/redis.conf
echo "maxmemory-policy allkeys-lru" | sudo tee -a /etc/redis/redis.conf

sudo systemctl restart redis-server

# Give each PHP-FPM process 256M
cat <<EOF > /etc/php/8.4/fpm/conf.d/mediawiki-tuning.ini
; priority=99
memory_limit = 256M
apc.shm_size = 256M
iopcache.memory_consumption = 128M
opcache.revalidate_freq = 5
opcache.interned_strings_buffer = 16
EOF

phpenmod -s fpm mediawiki-tuning

# Have PHP-FPM always run 8 processes
cat <<EOF > /etc/php/8.4/fpm/pool.d/zzz-mediawiki-tuning.conf
; bump up number of FPM processes allowed
pm = static
pm.max_children = 8
pm.max_requests = 500
EOF

# Install `luasandbox` and `redis` PHP extensions
LUASANDBOX_PKG="LuaSandbox-4.1.3"
apt install -y php-dev liblua5.1-0-dev
cd /tmp
wget https://pecl.php.net/get/${LUASANDBOX_PKG}.tgz
tar -xvzf ${LUASANDBOX_PKG}.tgz
cd ${LUASANDBOX_PKG}
phpize
./configure
make
make install

echo "extension = luasandbox" > /etc/php/8.4/mods-available/luasandbox.ini
phpenmod luasandbox

REDIS_PHP_PKG="redis-6.3.0"
cd /tmp
wget https://pecl.php.net/get/${REDIS_PHP_PKG}.tgz
tar -xvzf ${REDIS_PHP_PKG}.tgz
cd ${REDIS_PHP_PKG}
phpize
./configure
make
make install

echo "extension = redis" > /etc/php/8.4/mods-available/redis.ini
phpenmod redis

systemctl restart php8.4-fpm

# Register FPM with Apache
a2enmod proxy_fcgi setenvif rewrite
a2enconf php8.4-fpm

# Turn on some security support
a2enmod headers
a2enmod expires

# Create Apache Virtual Host configuration with SSL
a2enmod ssl

cat <<EOF > /etc/apache2/sites-available/${DOMAIN_NAME}.conf
<VirtualHost *:80>
    ServerName ${DOMAIN_NAME}
    Redirect permanent / https://${DOMAIN_NAME}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN_NAME}
    ServerAdmin ${ADMIN_EMAIL}
    DocumentRoot /var/www/mediawiki

    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-Content-Type-Options "nosniff"
    Header set X-XSS-Protection "1; mode=block"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    <Directory /var/www/mediawiki>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        <IfModule mod_rewrite.c>
            RewriteEngine On
            
            # Block aggressive scrapers that ignore robots.txt
            RewriteCond %{HTTP_USER_AGENT} (Bytespider|Curebot|PetalBot|DotBot|SemrushBot|MJ12bot) [NC]
            RewriteRule .* - [F,L]

            # Protect hidden system files
            RewriteRule "(^|/)\.(?!well-known\/)" - [F]
        </IfModule>

        # Prevent directory listing
        Options -Indexes
    </Directory>

    # Deny access to sensitive files
    <FilesMatch "(LocalSettings\.php|composer\.json|package\.json|\.sql|\.bak)$">
        Require all denied
    </FilesMatch>

    # Disable PHP execution in the uploads directory
    <Directory /var/www/mediawiki/images>
        <FilesMatch "\.(php|php5|php8|phtml|pl|py|jsp|asp|sh|cgi)$">
            Require all denied
        </FilesMatch>
    </Directory>

    # Caching for Static Assets (Optimizes PHP-FPM load)
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresDefault "access plus 1 month"
        ExpiresByType image/x-icon "access plus 1 year"
        ExpiresByType image/webp "access plus 1 month"
        ExpiresByType text/css "access plus 1 month"
        ExpiresByType application/javascript "access plus 1 month"
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}_access.log combined
</VirtualHost>
EOF

# Enable the new site and disable the default site
a2ensite ${DOMAIN_NAME}.conf
a2dissite 000-default.conf

# Build out SSL cert using Certbot
apt install -y certbot python3-certbot-apache
certbot --apache -d ${DOMAIN_NAME} -m ${ADMIN_EMAIL} --agree-tos --no-eff-email

# Restart Apache to apply all changes
systemctl restart apache2

# Download and Extract MediaWiki
cd /tmp
wget https://releases.wikimedia.org/mediawiki/${MW_MAJOR}/mediawiki-${MW_VERSION}.tar.gz
tar -xvzf mediawiki-${MW_VERSION}.tar.gz
mv mediawiki-${MW_VERSION} /var/www/mediawiki

# Set correct permissions
chown -R www-data:www-data /var/www/mediawiki
chmod -R 755 /var/www/mediawiki

# Create a phpinfo script to verify installation of luasandbox and APCu
echo "<?php phpinfo(); ?>" > /var/www/mediawiki/info.php
chown www-data:www-data /var/www/mediawiki/info.php

# Install additional MediaWiki extensions
cd /var/www/mediawiki/extensions/
git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/Variables
git clone -b REL1_45 https://gerrit.wikimedia.org/r/mediawiki/extensions/intersection
git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/NoTitle
git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/Screenplay
git clone -b REL1_45 https://gerrit.wikimedia.org/r/mediawiki/extensions/TimedMediaHandler
git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/MagicNoCache
git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/PipeEscape
git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/CloudflarePurge

# Set up base database schema for MediaWiki
# (This creates a LocalSettings.php file; just ignore it since we'll overwrite it.)
cd /var/www/mediawiki
php maintenance/run.php install --dbname $DB_NAME --dbuser $DB_USER --dbpass $DB_PASS \
    --pass "$MW_ADMIN_PASS" "WikiName" "$MW_ADMIN_USER"

# Set up a job runner service
cat <<EOF > /etc/systemd/system/mw-jobrunner.service
[Unit]
Description=MediaWiki Job Runner
After=network.target redis.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/var/www/mediawiki
ExecStart=/usr/bin/php /var/www/mediawiki/maintenance/runJobs.php --wait
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mw-jobrunner
systemctl start mw-jobrunner

# Build LocalSettings.php
SECRET_KEY=`cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64; echo`
UPGRADE_KEY=`cat /dev/urandom | tr -dc 'a-f0-9' | head -c 16; echo`

cat <<EOF > /var/www/mediawiki/LocalSettings.php
<?php
# This file was automatically generated by the MediaWiki 1.45.3
# installer. If you make manual changes, please keep track in case you
# need to recreate them later.
#
# See includes/MainConfigSchema.php for all configurable settings
# and their default values, but don't forget to make changes in _this_
# file, not there.
#
# Further documentation for configuration settings may be found at:
# https://www.mediawiki.org/wiki/Manual:Configuration_settings

# Protect against web entry
if ( !defined( 'MEDIAWIKI' ) ) {
	exit;
}

## Uncomment this to disable output compression
# \$wgDisableOutputCompression = true;

\$wgSitename = "${MW_NAME}";
\$wgMetaNamespace = "Project";

## The URL base path to the directory containing the wiki;
## defaults for all runtime URL paths are based off of this.
## For more information on customizing the URLs
## (like /w/index.php/Page_title to /wiki/Page_title) please see:
## https://www.mediawiki.org/wiki/Manual:Short_URL
\$wgScriptPath = "";

## The protocol and server name to use in fully-qualified URLs
\$wgServer = "https://${DOMAIN_NAME}";

## The URL path to static resources (images, scripts, etc.)
\$wgResourceBasePath = \$wgScriptPath;

## The URL paths to the logo.  Make sure you change this from the default,
## or else you'll overwrite your logo when you upgrade!
\$wgLogos = [
	'1x' => "\$wgResourceBasePath/resources/assets/change-your-logo.svg",
	'icon' => "\$wgResourceBasePath/resources/assets/change-your-logo.svg",
];

## UPO means: this is also a user preference option

\$wgEnableEmail = false;
\$wgEnableUserEmail = true; # UPO

\$wgEmergencyContact = "";
\$wgPasswordSender = "";

\$wgEnotifUserTalk = false; # UPO
\$wgEnotifWatchlist = false; # UPO
\$wgEmailAuthentication = true;

## Database settings
\$wgDBname = "${DB_NAME}";
\$wgDBservers = [
    [
        'host' => "localhost:/var/run/mysqld/mysqld.sock",
        'type' => "mysql",
        'user' => "${DB_USER}",
        'password' => "${DB_PASS}",
        'flags' => DBO_PERSISTENT,
        'load' => 0
    ]
];

# MySQL specific settings
\$wgDBprefix = "";
\$wgDBssl = false;

# MySQL table options to use during installation or update
\$wgDBTableOptions = "ENGINE=InnoDB, DEFAULT CHARSET=binary";

## Cache settings
\$wgObjectCaches['redis'] = [
    'class' => 'RedisBagOStuff',
    'servers' => [ '127.0.0.1:6379' ],
    'connectTimeout' => 1,
    'readTimeout' => 1,
    'persistent' => true,
];

\$wgMainCacheType = 'redis';
\$wgParserCacheType = 'redis';
\$wgMessageCacheType = 'redis';
\$wgSessionCacheType = 'redis';
\$wgUseFileCache = true;
\$wgCacheDirectory = "\$IP/cache";
\$wgShowIPinHeader = false;
\$wgInvalidateCacheOnEdit = true;

\$wgUseCdn = true;
\$wgCdnMaxAge = 2592000;
\$wgCdnServersNoPurge = [
    # Cloudflare IPv4
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/13',
    '104.24.0.0/14',
    '172.64.0.0/13',
    '131.0.72.0/22',
    
    # Cloudflare IPv6
    '2400:cb00::/32',
    '2606:4700::/32',
    '2803:f800::/32',
    '2405:b500::/32',
    '2405:8100::/32',
    '2a06:98c0::/29',
    '2c0f:f248::/32'
];
# This next line *is* correct!
\$wgCdnServers = [ ];

wfLoadExtension( 'CloudflarePurge' );
\$wgCloudflarePurgeZoneID = '${CF_ZONE_ID}';
\$wgCloudflarePurgeToken = '${CF_API_TOKEN}';

## To enable image uploads, make sure the 'images' directory
## is writable, then set this to true:
\$wgEnableUploads = false;
\$wgUseImageMagick = true;
\$wgImageMagickConvertCommand = "/usr/bin/convert";

# InstantCommons allows wiki to use images from https://commons.wikimedia.org
\$wgUseInstantCommons = false;

# Periodically send a pingback to https://www.mediawiki.org/ with basic data
# about this MediaWiki instance. The Wikimedia Foundation shares this data
# with MediaWiki developers to help guide future development efforts.
\$wgPingback = false;

# Site language code, should be one of the list in ./includes/languages/data/Names.php
\$wgLanguageCode = "en";

# Time zone
\$wgLocaltimezone = "UTC";

## Set \$wgCacheDirectory to a writable directory on the web server
## to make your wiki go slightly faster. The directory should not
## be publicly accessible from the web.
#\$wgCacheDirectory = "\$IP/cache";

\$wgSecretKey = "${SECRET_KEY}";

# Changing this will log out all existing sessions.
\$wgAuthenticationTokenVersion = "1";

# Site upgrade key. Must be set to a string (default provided) to turn on the
# web installer while LocalSettings.php is in place
\$wgUpgradeKey = "${UPGRADE_KEY}";

## For attaching licensing metadata to pages, and displaying an
## appropriate copyright notice / icon. GNU Free Documentation
## License and Creative Commons licenses are supported so far.
\$wgRightsPage = ""; # Set to the title of a wiki page that describes your license/copyright
\$wgRightsUrl = "";
\$wgRightsText = "";
\$wgRightsIcon = "";

# Path to the GNU diff3 utility. Used for conflict resolution.
\$wgDiff3 = "/usr/bin/diff3";

# The following permissions were set based on your choice in the installer
\$wgGroupPermissions["*"]["createaccount"] = false;
\$wgGroupPermissions["*"]["edit"] = false;

## Default skin: you can change the default skin. Use the internal symbolic
## names, e.g. 'vector' or 'monobook':
\$wgDefaultSkin = "vector";

# Enabled skins.
# The following skins were automatically enabled:
wfLoadSkin( 'MonoBook' );
wfLoadSkin( 'Timeless' );
wfLoadSkin( 'Vector' );


# Enabled extensions. Most of the extensions are enabled by adding
# wfLoadExtension( 'ExtensionName' );
# to LocalSettings.php. Check specific extension documentation for more details.
# The following extensions were automatically enabled:
wfLoadExtension( 'CategoryTree' );
wfLoadExtension( 'Cite' );
wfLoadExtension( 'CiteThisPage' );
wfLoadExtension( 'CodeEditor' );
wfLoadExtension( 'ConfirmEdit' );
wfLoadExtension( 'Echo' );
wfLoadExtension( 'Gadgets' );
wfLoadExtension( 'ImageMap' );
wfLoadExtension( 'InputBox' );
wfLoadExtension( 'intersection' );
# wfLoadExtension( 'Interwiki' );
# wfLoadExtension( 'LocalisationUpdate' );
wfLoadExtension( 'MultimediaViewer' );
wfLoadExtension( 'NoTitle' );
wfLoadExtension( 'Nuke' );
wfLoadExtension( 'OATHAuth' );
wfLoadExtension( 'ParserFunctions' );
wfLoadExtension( 'PdfHandler' );
wfLoadExtension( 'Poem' );
wfLoadExtension( 'ReplaceText' );
wfLoadExtension( 'Screenplay' );
wfLoadExtension( 'Scribunto' );
wfLoadExtension( 'SpamBlacklist' );
wfLoadExtension( 'SyntaxHighlight_GeSHi' );
wfLoadExtension( 'TemplateData' );
wfLoadExtension( 'TemplateStyles' );
wfLoadExtension( 'TextExtracts' );
wfLoadExtension( 'Thanks' );
wfLoadExtension( 'TitleBlacklist' );
wfLoadExtension( 'WikiEditor' );
wfLoadExtension( 'Variables' );


# End of automatically generated settings.
# Add more configuration options below.

\$wgScribuntoDefaultEngine = 'luasandbox';

// Set memory limit for Lua (in bytes). Default is usually 50MB (52428800).
\$wgScribuntoEngineConf['luasandbox']['memoryLimit'] = 52428800;

// Set CPU time limit (in seconds).
\$wgScribuntoEngineConf['luasandbox']['cpuLimit'] = 7;

##### Custom config here

\$wgRestrictDisplayTitle = false;

# Custom Namespace Settings

\$wgNamespacesWithSubpages[NS_MAIN] = true;
\$wgNamespacesWithSubpages[NS_TALK] = true; 
 
// Define constants for my additional namespaces.
define("NS_APPENDIX", 100); 
define("NS_APPENDIX_TALK", 101);
define("NS_SOURCES", 3000); 
define("NS_SOURCES_TALK", 3001);

// Add namespaces.
\$wgExtraNamespaces[NS_APPENDIX] = "Appendix";
\$wgExtraNamespaces[NS_APPENDIX_TALK] = "Appendix_talk";
\$wgExtraNamespaces[NS_SOURCES] = "Sources";
\$wgExtraNamespaces[NS_SOURCES_TALK] = "Sources_talk";
\$wgNamespacesWithSubpages[NS_APPENDIX] = true;
\$wgNamespacesWithSubpages[NS_APPENDIX_TALK] = true; 
\$wgNamespacesWithSubpages[NS_SOURCES] = true;
\$wgNamespacesWithSubpages[NS_SOURCES_TALK] = true; 

#Other Settings
# \$wgCapitalLinks = false;
// MediaWiki 1.31 and later
# wfLoadExtension( 'TimedMediaHandler' );
wfLoadExtension( 'MagicNoCache' );
wfLoadExtension( 'PipeEscape' );

## Turning on JavaScript
\$wgAllowUserJs = true;

## Disallow webcrawler robots
\$wgDefaultRobotPolicy = 'noindex,nofollow';

# \$wgDebugLogFile = "/tmp/debug.log";
\$wgShowExceptionDetails = false; 

## Job runner configuration
\$wgJobTypeConf['default'] = [
    'class'       => 'JobQueueRedis',
    'redisServer' => '127.0.0.1:6379',
    'redisConfig' => [
        'connectTimeout' => 1,
        'readTimeout' => 1,
    ],
    'claimTTL'    => 3600,
    'daemonized'  => true
];
\$wgJobRunRate = 0;
EOF

# update DB schema
php maintenance/run.php update --quick

# add a robots.txt
cat <<EOF > /var/www/mediawiki/robots.txt
User-agent: *
Disallow: /
EOF

# change ownership of mediawiki/ files
chown -R ${CLI_USER}:${CLI_USER} /var/www/mediawiki/

# allow www-data processes to write to file cache
chown www-data:www-data /var/www/mediawiki/cache

# set up cron job to prune the file cache every 7 days
crontab -u ${CLI_USER} - <<EOF
0 2 * * * /usr/bin/php /var/www/mediawiki/maintenance/run.php pruneFileCache --agedays 7 > /tmp/pruneCache.log 2>&1
EOF