#!/bin/bash
while getopts ":i:o:b:h:e:" OPTNAME; do
	case $OPTNAME in
		i)
			echo "Server ID: ${OPTARG}"
			server_id="${OPTARG}"
			;;
		o)
			echo "Offset: ${OPTARG}"
			offset="${OPTARG}"
			;;
		b)
			echo "Bucket Name: ${OPTARG}"
			bucket_name="${OPTARG}"
			;;
		h)
			echo "Hostname Prefix: ${OPTARG}"
			hostname_prefix="${OPTARG}"
			;;
		e)
			echo "Environment Suffix: ${OPTARG}"
			environment_suffix="${OPTARG}"
			;;
	esac
done

if [ -z "${server_id}" -o -z "${offset}" -o -z "${bucket_name}" ]; then
	echo "Usage: ${BASH_SOURCE[0]} -i server_id -o offset -b files_bucket_name [-h hostname_prefix] [-e environment_suffix]"
	exit 1
fi

ip="$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
name="$(hostname)"
iam_role="$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)"
scripts="https://raw.githubusercontent.com/iVirus/gentoo_bootstrap_java/master/templates/hvm/scripts"

declare "$(dhcpcd -4T eth0 | grep ^new_domain_name_servers | tr -d \')"

svc -d /service/dnscache || exit 1

filename="var/dnscache/root/servers/@"
echo "--- ${filename} (replace)"
tr ' ' '\n' <<< "${new_domain_name_servers}" > "/${filename}"

svc -u /service/dnscache || exit 1

filename="usr/local/bin/encrypt_decrypt"
functions_file="$(mktemp)"
curl -sf -o "${functions_file}" "${scripts}/${filename}" || exit 1
source "${functions_file}"

dirname="etc/portage/repos.conf"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"

filename="etc/portage/repos.conf/gentoo.conf"
echo "--- ${filename} (replace)"
cp "/usr/share/portage/config/repos.conf" "/${filename}" || exit 1
sed -i -r \
-e "\|^\[gentoo\]$|,\|^$|s|^(sync\-uri\s+\=\s+rsync\://).*|\1${hostname_prefix}systems1/gentoo\-portage|" \
"/${filename}"

emerge -q --sync || exit 1

filename="var/lib/portage/world"
echo "--- ${filename} (append)"
cat <<'EOF'>>"/${filename}"
dev-db/mytop
dev-db/percona-server
dev-libs/libmemcached
dev-php/PEAR-Mail
dev-php/PEAR-Mail_Mime
dev-php/PEAR-Spreadsheet_Excel_Writer
dev-php/pear
dev-python/mysql-python
dev-qt/qtwebkit:4
net-fs/s3fs
net-libs/libssh2
net-misc/memcached
sys-apps/miscfiles
sys-apps/pv
sys-process/at
EOF

filename="etc/portage/package.use/libmemcached"
echo "--- ${filename} (replace)"
cat <<'EOF'>"/${filename}"
dev-libs/libmemcached sasl
EOF

filename="etc/portage/package.use/mysql"
echo "--- ${filename} (modify)"
sed -i -r \
-e "s|mysql|percona-server|" \
-e "s|minimal|extraengine profiling|" \
"/${filename}" || exit 1

filename="etc/portage/package.use/php"
echo "--- ${filename} (replace)"
cat <<'EOF'>"/${filename}"
dev-lang/php bcmath calendar curl exif ftp gd inifile intl mysql mysqli pcntl pdo sharedmem snmp soap sockets spell sysvipc truetype xmlreader xmlrpc xmlwriter zip
EOF

dirname="etc/portage/package.keywords"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"

filename="etc/portage/package.keywords/libmemcached"
echo "--- ${filename} (replace)"
cat <<'EOF'>"/${filename}"
dev-libs/libmemcached
EOF

filename="etc/portage/package.keywords/mysql"
echo "--- ${filename} (replace)"
cat <<'EOF'>"/${filename}"
dev-db/percona-server
EOF

#mirrorselect -D -b10 -s5 || exit 1

filename="etc/portage/make.conf"
echo "--- ${filename} (modify)"
sed -i -r \
-e "\|^EMERGE_DEFAULT_OPTS|a PORTAGE_BINHOST\=\"http\://${hostname_prefix}bin1/packages\"" \
"/${filename}" || exit 1

#emerge -uDNg @system @world || emerge --resume || exit 1
emerge -uDN @system @world || emerge --resume || exit 1

revdep-rebuild || exit 1

filename="etc/fstab"
echo "--- ${filename} (append)"
cat <<EOF>>"/${filename}"

s3fs#${bucket_name}	/mnt/s3		fuse	_netdev,allow_other,url=https://s3.amazonaws.com,iam_role=${iam_role}	0 0
EOF

dirname="mnt/s3"
echo "--- ${dirname} (mount)"
mkdir -p "/${dirname}"
mount "/${dirname}" || exit 1

dirname="var/www"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"

dirname="mnt/s3/repository/sta_files"
linkname="var/www/sta_files"
echo "--- ${linkname} -> ${dirname} (softlink)"
ln -s "/${dirname}/" "/${linkname}" || exit 1

dirname="mnt/s3/repository/sta_files_recycle_bin"
linkname="var/www/sta_files_recycle_bin"
echo "--- ${linkname} -> ${dirname} (softlink)"
ln -s "/${dirname}/" "/${linkname}" || exit 1

dirname="mnt/s3/repository/sta2_files"
linkname="var/www/sta2_files"
echo "--- ${linkname} -> ${dirname} (softlink)"
ln -s "/${dirname}/" "/${linkname}" || exit 1

dirname="mnt/s3/repository/sta2_files_recycle_bin"
linkname="var/www/sta2_files_recycle_bin"
echo "--- ${linkname} -> ${dirname} (softlink)"
ln -s "/${dirname}/" "/${linkname}" || exit 1

filename="etc/conf.d/memcached"
echo "--- ${filename} (modify)"
cp "/${filename}" "/${filename}.orig"
sed -i -r \
-e "s|^MEMUSAGE\=.*|MEMUSAGE\=\"512\"|" \
-e "s|^MAXCONN\=.*|MAXCONN\=\"2048\"|" \
-e "s|^LISTENON\=.*|LISTENON\=\"0\.0\.0\.0\"|" \
"/${filename}"

/etc/init.d/memcached start || exit 1

rc-update add memcached default

/etc/init.d/atd start || exit 1

rc-update add atd default

my_first_file="$(mktemp)"
cat <<'EOF'>"${my_first_file}"

max_connections			= 650
max_user_connections		= 600
skip-name-resolve
sql-mode			= NO_AUTO_CREATE_USER
EOF

my_second_file="$(mktemp)"
cat <<EOF>"${my_second_file}"

expire_logs_days		= 2
slow_query_log
relay-log			= /var/log/mysql/binary/mysqld-relay-bin
log_slave_updates
auto_increment_increment	= 2
auto_increment_offset		= ${offset}
EOF

filename="etc/mysql/my.cnf"
echo "--- ${filename} (modify)"
cp "/${filename}" "/${filename}.orig"
sed -i -r \
-e "\|^lc_messages\s+\=\s+|r ${my_first_file}" \
-e "s|^(bind\-address\s+\=\s+.*)|#\1|" \
-e "s|^(log\-bin)|\1\t\t\t\t\= /var/log/mysql/binary/mysqld\-bin|" \
-e "s|^(server\-id\s+\=\s+).*|\1${server_id}|" \
-e "\|^server\-id\s+\=\s+|r ${my_second_file}" \
-e "s|^(innodb_data_file_path\s+\=\s+.*)|#\1|" \
"/${filename}" || exit 1

dirname="var/log/mysql/binary"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"
chmod 700 "/${dirname}" || exit 1
chown mysql: "/${dirname}" || exit 1

yes "" | emerge --config dev-db/percona-server || exit 1

/etc/init.d/mysql start || exit 1

rc-update add mysql default

mysql_secure_installation <<'EOF'

n
y
y
n
y
EOF

filename="etc/mysql/configure_as_standalone.sql"
configure_standalone_file="$(mktemp)"
curl -sf -o "${configure_standalone_file}" "${scripts}/${filename}" || exit 1

user="bmoorman"
app="mysql"
type="hash"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

user="ecall"
app="mysql"
type="hash"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

user="tpurdy"
app="mysql"
type="hash"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

user="npeterson"
app="mysql"
type="hash"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

user="monitoring"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

user="mytop"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

sed -i -r \
-e "s|%BMOORMAN_HASH%|${bmoorman_mysql_hash}|" \
-e "s|%ECALL_HASH%|${ecall_mysql_hash}|" \
-e "s|%TPURDY_HASH%|${tpurdy_mysql_hash}|" \
-e "s|%NPETERSON_HASH%|${npeterson_mysql_hash}|" \
-e "s|%MONITORING_AUTH%|${monitoring_mysql_auth}|" \
-e "s|%MYTOP_AUTH%|${mytop_mysql_auth}|" \
"${configure_standalone_file}" || exit 1

mysql < "${configure_standalone_file}" || exit 1

filename="etc/skel/.mytop"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1

user="mytop"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

sed -i -r \
-e "s|%MYTOP_AUTH%|${mytop_mysql_auth}|" \
"/${filename}" || exit 1

dirname="usr/lib64/nagios/plugins/custom/include"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"

filename="usr/lib64/nagios/plugins/custom/check_mysql_connections"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1
chmod 755 "/${filename}" || exit 1

filename="usr/lib64/nagios/plugins/custom/include/settings.inc"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1

user="monitoring"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

sed -i -r \
-e "s|%MONITORING_AUTH%|${monitoring_mysql_auth}|" \
"/${filename}" || exit 1

dirname="usr/local/lib64/mysql/include"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"

filename="usr/local/lib64/mysql/watch_mysql_connections.php"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1
chmod 755 "/${filename}" || exit 1

filename="usr/local/lib64/mysql/include/settings.inc"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1

filename="etc/init.d/watch-mysql-connections"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename%-*}" || exit 1
chmod 755 "/${filename}" || exit 1

/${filename} start || exit 1

rc-update add ${filename##*/} default

user="monitoring"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

sed -i -r \
-e "s|%MONITORING_AUTH%|${monitoring_mysql_auth}|" \
"/${filename}" || exit 1

filename="usr/lib64/ganglia/python_modules/DBUtil.py"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "https://raw.githubusercontent.com/ganglia/monitor-core/master/gmond/python_modules/db/mysql.py" || exit 1

filename="usr/lib64/ganglia/python_modules/mysql.py"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "https://raw.githubusercontent.com/ganglia/monitor-core/master/gmond/python_modules/db/DBUtil.py" || exit 1

filename="etc/ganglia/conf.d/mysql.pyconf"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "https://raw.githubusercontent.com/ganglia/monitor-core/master/gmond/python_modules/conf.d/mysql.pyconf.disabled" || exit 1

user="monitoring"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

sed -i -r \
-e "s|your_user|monitoring|" \
-e "s|your_password|${monitoring_mysql_auth}|" \
"/${filename}"

for i in memcache memcached mongo oauth-1.2.3 ssh2; do
	yes "" | pecl install "${i}" > /dev/null || exit 1

	dirname="etc/php"
	echo "--- ${dirname} (processing)"

	for j in $(ls "/${dirname}"); do
		filename="${dirname}/${j}/ext/${i%-*}.ini"
		echo "--- ${filename} (replace)"
		cat <<EOF>"/${filename}"
extension=${i%-*}.so
EOF

		linkname="${dirname}/${j}/ext-active/${i%-*}.ini"
		echo "--- ${linkname} -> ${filename} (softlink)"
		ln -s "/${filename}" "/${linkname}" || exit 1
        done
done

filename="usr/local/bin/wkhtmltopdf"
echo "--- ${filename} (replace)"
wkhtmltopdf_file="$(mktemp)"
curl -sf -o "${wkhtmltopdf_file}" "http://download.gna.org/wkhtmltopdf/obsolete/linux/wkhtmltopdf-0.11.0_rc1-static-amd64.tar.bz2" || exit 1
tar xjf "${wkhtmltopdf_file}" -C "/${filename%/*}" || exit 1
mv "/${filename}-amd64" "/${filename}" || exit 1

linkname="usr/bin/wkhtmltopdf"
echo "--- ${linkname} -> ${filename} (softlink)"
ln -s "/${filename}" "/${linkname}" || exit 1

filename="usr/local/bin/wkhtmltoimage"
echo "--- ${filename} (replace)"
wkhtmltoimage_file="$(mktemp)"
curl -sf -o "${wkhtmltoimage_file}" "http://download.gna.org/wkhtmltopdf/obsolete/linux/wkhtmltoimage-0.11.0_rc1-static-amd64.tar.bz2" || exit 1
tar xjf "${wkhtmltoimage_file}" -C "/${filename%/*}" || exit 1
mv "/${filename}-amd64" "/${filename}" || exit 1

linkname="usr/bin/wkhtmltoimage"
echo "--- ${linkname} -> ${filename} (softlink)"
ln -s "/${filename}" "/${linkname}" || exit 1

nrpe_file="$(mktemp)"
cat <<'EOF'>"${nrpe_file}"

command[check_atd]=/usr/lib64/nagios/plugins/check_procs -c 1: -C atd -a /usr/sbin/atd
command[check_memcached]=/usr/lib64/nagios/plugins/check_procs -c 1: -C memcached -a /usr/bin/memcached
command[check_mysqld]=/usr/lib64/nagios/plugins/check_procs -c 1: -C mysqld -a /usr/sbin/mysqld
command[check_mysql_connections]=/usr/lib64/nagios/plugins/custom/check_mysql_connections
command[check_mysql_disk]=/usr/lib64/nagios/plugins/check_disk -w 20% -c 10% -p /var/lib/mysql
command[check_s3fs]=/usr/lib64/nagios/plugins/check_procs -c 1: -C s3fs -a s3fs
EOF

filename="etc/nagios/nrpe.cfg"
echo "--- ${filename} (modify)"
sed -i -r \
-e "\|^command\[check_total_procs\]|r ${nrpe_file}" \
-e "s|%HOSTNAME_PREFIX%|${hostname_prefix}|" \
"/${filename}" || exit 1

/etc/init.d/nrpe restart || exit 1

filename="etc/ganglia/gmond.conf"
echo "--- ${filename} (modify)"
cp "/${filename}" "/${filename}.orig"
sed -i -r \
-e "\|^cluster\s+\{$|,\|^\}$|s|(\s+name\s+\=\s+)\".*\"|\1\"Worker\"|" \
-e "\|^cluster\s+\{$|,\|^\}$|s|(\s+owner\s+\=\s+)\".*\"|\1\"InsideSales\.com, Inc\.\"|" \
-e "\|^udp_send_channel\s+\{$|,\|^\}$|s|(\s+)(mcast_join\s+\=\s+.*)|\1#\2\n\1host \= ${name}|" \
-e "\|^udp_recv_channel\s+\{$|,\|^\}$|s|(\s+)(mcast_join\s+\=\s+.*)|\1#\2|" \
-e "\|^udp_recv_channel\s+\{$|,\|^\}$|s|(\s+)(bind\s+\=\s+.*)|\1#\2|" \
"/${filename}"

/etc/init.d/gmond start || exit 1

rc-update add gmond default

yes "" | emerge --config mail-mta/netqmail || exit 1

ln -s /var/qmail/supervise/qmail-send/ /service/qmail-send || exit 1

curl -sf "http://${hostname_prefix}ns1:8053?type=A&name=${name}&domain=salesteamautomation.com&address=${ip}" || curl -sf "http://${hostname_prefix}ns2:8053?type=A&name=${name}&domain=salesteamautomation.com&address=${ip}" || exit 1

echo "--- SUCCESS :)"
