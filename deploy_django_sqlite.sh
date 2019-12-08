#!/bin/bash

# check if we're being run as root
echo "Checking if running as root..."
if [[ "$EUID" -ne 0 ]]; then
        echo "Please run as root"
        exit
    fi
echo "Completed checking if running as root.."

echo

# conventional values that we'll use throughout the script
APPNAME=$1
DOMAINNAME=$2
GIT=$3
PROJECT_NAME=$4
PYTHON_VERSION=$5

# check appname was supplied as argument
if [[ "$APPNAME" == "" ]]; then
   echo "Usage:"
   echo "  $ ./deploy_django_sqlite.sh <appname>"
   echo
   exit 1
fi

# Upgrade packages
echo "Starting apt-get update..."
apt-get update
echo "Completed apt-get update..."

echo

echo "Starting apt-get -y upgrade..."
apt-get -y upgrade
apt autoremove
echo "Completed apt-get -y upgrade..."

echo

# Default python version to 3. OS has to have it installed.
if [[ "$PYTHON_VERSION" == "" ]]; then
PYTHON_VERSION=3
fi

# Install mysql
echo "Start installing mysql..."
apt-get install mysql-server
systemctl start mysql
#systemctl status mysql.service
echo "Completed installing mysql..."

echo "Setup mysql..."
apt-get install python3-dev libmysqlclient-dev
apt-get install build-essential
mysql -u root -p  << EOF
GRANT ALL PRIVILEGES ON *.* TO '$APPNAME'@'localhost' IDENTIFIED BY '#VU4jFgek';
CREATE DATABASE IF NOT EXISTS $APPNAME;
SHOW DATABASES;
EOF

# Install nginx
echo "Start installing nginx..."
apt-get -y install nginx
echo "Completed installing nginx..."

echo

# Setup supervisor
echo "Starting installing supervisor..."
apt-get -y install supervisor
echo "Completed installing supervisor..."

echo

echo "Starting and enabling supervisor..."
systemctl enable supervisor
systemctl start supervisor
echo "Completed starting and enabling supervisor..."

echo

# Python virtualenv
echo "Start installing python-virtualenv..."
apt-get -y install python-virtualenv
echo "Completed installing python-virtualenv..."

echo

# clear old data
echo "Clearing old data..."
su -l $APPNAME << EOF
sudo supervisorctl stop $APPNAME
EOF

# deluser $APPNAME
sudo rm /etc/supervisor/conf.d/$APPNAME.conf
# rm -r * /home/$APPNAME
echo "Clearing old data complete..."

echo

echo "Checking if user exists..."
/bin/egrep  -i "^${APPNAME}:" /etc/passwd
if [[ $? -eq 0 ]]; then
   echo "User $APPNAME exists in /etc/passwd"
else
   echo "User $APPNAME does not exists in /etc/passwd"
   # Configure application user
   echo "Start configuring app user..."
   adduser $APPNAME
   echo "Completed creating app user..."
   echo "Add user to list of sudoers..."
   gpasswd -a $APPNAME sudo
   echo "User added to list of sudoers..."

   echo
   echo "Switching to recently created user..."
   su -l $APPNAME << 'EOF'
   pwd
   echo "Setting up python virtualenv..."
   virtualenv -p python3 .
EOF
fi

echo

su -l $APPNAME << EOF
source bin/activate
# upgrade pip
pip install --upgrade pip
EOF

# check if git exists
if [[ -d "/home/$APPNAME/$APPNAME" ]]
then
    echo "Git repo exists."
    echo "Performing a git pull..."
    cd /home/$APPNAME/$APPNAME/
    git add .
    git commit -m "Server stage before deployment"
    git pull origin master
else
    echo "Git repo does not exists."
    # Cloning git
su -l $APPNAME << EOF
echo "Cloning git repo..."
mkdir $APPNAME
EOF

echo

pwd
cd /home/$APPNAME/$APPNAME/
pwd
git clone $GIT .
su -l $APPNAME << EOF
cd $APPNAME
pwd
echo "Cloned git repo..."

echo
EOF
fi


su -l $APPNAME << EOF
cd $APPNAME
echo

echo "Installing dependencies..."
pip install -r requirements.txt

echo "Migrating current db and static files..."
python manage.py makemigrations
python manage.py migrate
EOF

echo

echo "Setting media files folder permissions..."
sudo chmod -R 777 /home/$APPNAME/$APPNAME/media/

echo

# echo "Change db permission..."
# sudo chmod 777 /home/$APPNAME/$APPNAME/db.sqlite3

echo

# Gunicorn
echo "Configuring gunicorn"
cat > /tmp/gunicorn_start << EOF
#!/bin/bash


NAME="$APPNAME"
DIR=/home/$APPNAME/$APPNAME
USER=$APPNAME
GROUP=$APPNAME
WORKERS=3
BIND=unix:/home/$APPNAME/run/gunicorn.sock
DJANGO_SETTINGS_MODULE=${PROJECT_NAME}.settings
DJANGO_WSGI_MODULE=${PROJECT_NAME}.wsgi
LOG_LEVEL=error

cd \$DIR
source ../bin/activate

export DJANGO_SETTINGS_MODULE=\$DJANGO_SETTINGS_MODULE
export PYTHONPATH=\$DIR:\$PYTHONPATH

exec ../bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name \$NAME \
  --workers \$WORKERS \
  --user=\$USER \
  --group=\$GROUP \
  --bind=\$BIND \
  --log-level=\$LOG_LEVEL \
  --log-file=-
EOF


mv /tmp/gunicorn_start /home/$APPNAME/bin/
chown $APPNAME:$APPNAME /home/$APPNAME/bin/gunicorn_start
chmod u+x /home/$APPNAME/bin/gunicorn_start

su -l $APPNAME << EOF
echo "Configured gunicorn..."

echo

echo "mkdir run & logs...."
mkdir run
mkdir logs

echo

echo "Creating file to log errors..."
touch logs/gunicorn-error.log

echo

EOF

echo "Creating supervisor file..."

sudo rm /etc/supervisor/conf.d/$APPNAME.conf
sudo cat > /etc/supervisor/conf.d/$APPNAME.conf << EOF
[program:$APPNAME]
command=/home/$APPNAME/bin/gunicorn_start
user=$APPNAME
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/home/$APPNAME/logs/gunicorn-error.log
EOF

echo
su -l $APPNAME << EOF
echo "Rereading supervisor configuration files..."
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart $APPNAME

echo

echo "Checking program status..."
sudo supervisorctl status $APPNAME
echo
EOF

echo "Setting up nginx..."
echo "Removing existing app nginx config if any..."
su -l $APPNAME << EOF
sudo rm /etc/nginx/sites-enabled/$APPNAME
EOF

echo

echo "Creating new nginx config..."
su -l $APPNAME << EOF

echo "Removing nginx default website..."
sudo rm /etc/nginx/sites-enabled/$APPNAME
sudo rm /etc/nginx/sites-available/$APPNAME
EOF

sudo cat > /etc/nginx/sites-available/$APPNAME << EOF
upstream $APPNAME {
    server unix:/home/$APPNAME/run/gunicorn.sock fail_timeout=0;
}

server {
    listen 80;

    # add here the ip address of your server
    # or a domain pointing to that ip (like example.com or www.example.com)
    server_name $DOMAINNAME;

    keepalive_timeout 5;
    client_max_body_size 4G;

    access_log /home/$APPNAME/logs/nginx-access.log;
    error_log /home/$APPNAME/logs/nginx-error.log;

    location /static/ {
        alias /home/$APPNAME/$APPNAME/static/;
    }

    # checks for static file, if not found proxy to app
    location / {
        try_files \$uri @proxy_to_app;
    }

    location @proxy_to_app {
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header Host \$http_host;
      proxy_redirect off;
      proxy_pass http://$APPNAME;
    }
}

EOF

echo

echo "Creating symbolic link to sites-enabled..."
su -l $APPNAME << EOF
sudo ln -s /etc/nginx/sites-available/$APPNAME /etc/nginx/sites-enabled/$APPNAME
EOF
echo
echo "Restarting nginx..."
nginx -t
sudo service nginx reload

echo


echo "Set up ssl..."
sudo add-apt-repository ppa:certbot/certbot
sudo apt install python-certbot-nginx
sudo ufw allow 'Nginx Full'
sudo ufw delete allow 'Nginx HTTP'
sudo certbot --nginx -d $DOMAINNAME


echo "Deployment complete!"


