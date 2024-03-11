#!/bin/bash

# Update package lists
sudo apt update -y

# Download and install Zabbix repository
wget https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-4+ubuntu$(lsb_release -rs)_all.deb
sudo dpkg -i zabbix-release_6.0-4+ubuntu$(lsb_release -rs)_all.deb
sudo apt update -y
sudo apt -y install zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

# Install MariaDB
sudo apt install software-properties-common -y
wget https://r.mariadb.com/downloads/mariadb_repo_setup
sudo bash mariadb_repo_setup --mariadb-server-version=10.6
sudo apt update
sudo apt -y install mariadb-common mariadb-server-10.6 mariadb-client-10.6
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Prompt user for MariaDB root password
read -sp "Enter MariaDB root Password: " maria_root_password
echo

# Configure MariaDB
sudo mysql -u root -p"$maria_root_password" <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '$maria_root_password';
FLUSH PRIVILEGES;
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
FLUSH PRIVILEGES;
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Prompt user for Zabbix database user password
read -sp "Enter Zabbix Database Password: " zabbix_db_password
echo

# Create Zabbix database and user
sudo mysql -uroot -p"$maria_root_password" -e "create database zabbix character set utf8mb4 collate utf8mb4_bin;"
sudo mysql -uroot -p"$maria_root_password" -e "create user 'zabbix'@'localhost' identified by '$zabbix_db_password';"
sudo mysql -uroot -p"$maria_root_password" -e "grant all privileges on zabbix.* to zabbix@localhost identified by '$zabbix_db_password';"
sudo zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p"$zabbix_db_password" zabbix

# Configure Zabbix server
sudo sed -i "s/# DBPassword=.*/DBPassword=$zabbix_db_password/" /etc/zabbix/zabbix_server.conf

# Allow necessary ports in UFW
sudo systemctl start ufw
sudo systemctl enable ufw
sudo ufw allow 10050/tcp
sudo ufw allow 10051/tcp
sudo ufw allow 80/tcp
sudo ufw reload

# Restart Zabbix server and agent
sudo systemctl restart zabbix-server zabbix-agent
sudo systemctl enable zabbix-server zabbix-agent

# Configure PHP timezone for Apache
sudo sed -i 's/php_value date.timezone Europe\/Riga/php_value date.timezone Asia\/Yangon/' /etc/zabbix/apache.conf
sudo systemctl restart apache2
sudo systemctl enable apache2

# Get the local IP address
local_ip=$(hostname -I | awk '{print $1}')

# Define the output folder
output_folder="/root/zabbix_cert"

# Check if the output folder already exists
if [ ! -d "$output_folder" ]; then
    # Create the output folder if it doesn't exist
    mkdir -p "$output_folder"
    echo "Output folder created: $output_folder"
else
    echo "Output folder already exists: $output_folder"
fi

# Generate RSA private key
openssl genrsa -out "$output_folder/zabbix.key" 2048

# Generate Certificate Signing Request (CSR)
openssl req -new -key "$output_folder/zabbix.key" -out "$output_folder/zabbix.csr" -subj "/C=MM/ST=Yangon/L=Yangon/O=AGB/OU=AGB/CN=zabbix.com"

# Generate Self-Signed Certificate (valid for 700 days)
openssl x509 -req -days 700 -in "$output_folder/zabbix.csr" -signkey "$output_folder/zabbix.key" -out "$output_folder/zabbix.crt"

# Remove the CSR file
rm "$output_folder/zabbix.csr"

sudo a2enmod ssl
sudo a2enmod rewrite
sudo systemctl restart apache2
config_file="/etc/apache2/sites-available/000-default.conf"

cat > "$config_file" <<EOL
<VirtualHost *:80>
    ServerName zabbix.com
    Redirect permanent / https://$local_ip/
</VirtualHost>

<VirtualHost *:443>
    ServerName zabbix.com
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile /root/zabbix_cert/zabbix.crt
    SSLCertificateKeyFile /root/zabbix_cert/zabbix.key

    RewriteEngine On
    RewriteRule ^/$ /zabbix/ [R,L]
</VirtualHost>
EOL

# Restart Apache2 Server
sudo systemctl restart apache2

# Output
echo
echo "URL : https://$local_ip/"
echo "Default Web Username : Admin"
echo "Default Web Password : zabbix"
echo "MariaDB Password : $maria_root_password"
echo "ZabbixDB Password : $zabbix_db_password"
echo