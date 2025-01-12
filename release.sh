# send debs to server
rsync -azP --include './' --include '*.deb' --exclude '*' ./output/ ferreo@direct.pika-os.com:/srv/www/cockatiel-incoming/
