# check and init tx db
if [ ! -e "${MARIADB}" ]; then
    mariadb-install-db --datadir=${MARIADB}
    /usr/bin/mariadbd-safe --datadir=${MARIADB} &
    echo "Mariadb is created.  Please attach to container as root, and modify/run /data/mysql-db-init.sql"
    echo
    echo "   docker container exec -it -u root \<container id\> ash"
    echo "   \<container\> : mariadb -u root < /data/mysql-db-init.sql"
    echo
else
    /usr/bin/mariadbd-safe --datadir=${MARIADB} &
fi

