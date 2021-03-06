#!/bin/bash
while getopts ":m:i:o:b:h:e:" OPTNAME; do
	case $OPTNAME in
		m)
			echo "Master: ${OPTARG}"
			master="${OPTARG}"
			;;
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

if [ -z "${master}" -o -z "${server_id}" -o -z "${offset}" -o -z "${bucket_name}" ]; then
	echo "Usage: ${BASH_SOURCE[0]} -m master_name:master_ip -i server_id -o offset -b backup_bucket_name [-h hostname_prefix] [-e environment_suffix]"
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

filename="etc/hosts"
echo "--- ${filename} (append)"
cat <<EOF>>"/${filename}"

${master#*:}	${master%:*}.salesteamautomation.com ${master%:*}
EOF

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
dev-python/mysql-python
net-fs/s3fs
sys-apps/pv
sys-fs/lvm2
EOF

filename="etc/portage/package.use/lvm2"
echo "--- ${filename} (replace)"
cat <<'EOF'>"/${filename}"
sys-fs/lvm2 -thin
EOF

filename="etc/portage/package.use/mysql"
echo "--- ${filename} (modify)"
sed -i -r \
-e "s|mysql|percona-server|" \
-e "s|minimal|extraengine profiling|" \
"/${filename}" || exit 1

dirname="etc/portage/package.keywords"
echo "--- ${dirname} (create)"
mkdir -p "/${dirname}"

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

/etc/init.d/lvm start || exit 1

rc-update add lvm boot

filename="etc/fstab"
echo "--- ${filename} (append)"
cat <<EOF>>"/${filename}"

s3fs#${bucket_name}	/mnt/s3		fuse	_netdev,allow_other,url=https://s3.amazonaws.com,iam_role=${iam_role}	0 0
EOF

dirname="mnt/s3"
echo "--- ${dirname} (mount)"
mkdir -p "/${dirname}"
mount "/${dirname}" || exit 1

my_first_file="$(mktemp)"
cat <<'EOF'>"${my_first_file}"

des-key-file			= /etc/mysql/sta.key
thread_cache_size		= 64
query_cache_size		= 128M
query_cache_limit		= 32M
tmp_table_size			= 128M
max_heap_table_size		= 128M
max_connections			= 650
max_user_connections		= 600
skip-name-resolve
open_files_limit		= 65536
myisam_repair_threads		= 2
table_definition_cache		= 4096
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

my_third_file="$(mktemp)"
cat <<EOF>"${my_third_file}"

innodb_flush_method		= O_DIRECT
innodb_thread_concurrency	= 48
innodb_concurrency_tickets	= 5000
innodb_io_capacity		= 1000
EOF

filename="etc/mysql/my.cnf"
echo "--- ${filename} (modify)"
cp "/${filename}" "/${filename}.orig"
sed -i -r \
-e "s|^(key_buffer_size\s+\=\s+).*|\124576M|" \
-e "s|^(max_allowed_packet\s+\=\s+).*|\116M|" \
-e "s|^(table_open_cache\s+\=\s+).*|\116384|" \
-e "s|^(sort_buffer_size\s+\=\s+).*|\12M|" \
-e "s|^(read_buffer_size\s+\=\s+).*|\1128K|" \
-e "s|^(read_rnd_buffer_size\s+\=\s+).*|\1128K|" \
-e "s|^(myisam_sort_buffer_size\s+\=\s+).*|\164M|" \
-e "\|^lc_messages\s+\=\s+|r ${my_first_file}" \
-e "s|^(bind\-address\s+\=\s+.*)|#\1|" \
-e "s|^(log\-bin)|\1\t\t\t\t\= /var/log/mysql/binary/mysqld\-bin|" \
-e "s|^(server\-id\s+\=\s+).*|\1${server_id}|" \
-e "\|^server\-id\s+\=\s+|r ${my_second_file}" \
-e "s|^(innodb_buffer_pool_size\s+\=\s+).*|\132768M|" \
-e "s|^(innodb_data_file_path\s+\=\s+.*)|#\1|" \
-e "s|^(innodb_log_file_size\s+\=\s+).*|\11024M|" \
-e "s|^(innodb_flush_log_at_trx_commit\s+\=\s+).*|\12|" \
-e "\|^innodb_file_per_table|r ${my_third_file}" \
"/${filename}" || exit 1

filename="etc/mysql/sta.key"
echo "--- ${filename} (replace)"
cat <<'EOF'>"/${filename}"
0 
1 
2 
3 
4 
5 
6 
7 
8 
9 
EOF
chmod 600 "/${filename}" || exit 1
chown mysql: "/${filename}" || exit 1

pvcreate /dev/xvd[h] || exit 1
vgcreate vg1 /dev/xvd[h] || exit 1
lvcreate -l 100%VG -n lvol1 vg1 || exit 1
mkfs.ext4 /dev/vg1/lvol1 || exit 1

filename="etc/fstab"
echo "--- ${filename} (append)"
cat <<'EOF'>>"/${filename}"

/dev/vg1/lvol1	/var/log/mysql/binary	ext4		noatime		0 0
EOF

dirname="var/log/mysql/binary"
echo "--- ${dirname} (mount)"
mkdir -p "/${dirname}"
mount "/${dirname}" || exit 1
chmod 700 "/${dirname}" || exit 1
chown mysql: "/${dirname}" || exit 1

filename="usr/lib64/mysql/plugin/libmysql_strip_phone.so"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1

filename="usr/lib64/mysql/plugin/libmysql_format_phone.so"
echo "--- ${filename} (replace)"
curl -sf -o "/${filename}" "${scripts}/${filename}" || exit 1

yes "" | emerge --config dev-db/percona-server || exit 1

pvcreate /dev/xvd[fg] || exit 1
vgcreate vg0 /dev/xvd[fg] || exit 1
lvcreate -l 100%VG -n lvol0 vg0 || exit 1
mkfs.ext4 /dev/vg0/lvol0 || exit 1

filename="etc/fstab"
echo "--- ${filename} (append)"
cat <<'EOF'>>"/${filename}"

/dev/vg0/lvol0		/var/lib/mysql	ext4		noatime		0 0
EOF

dirname="var/lib/mysql"
echo "--- ${dirname} (mount)"
mv "/${dirname}" "/${dirname}.bak" || exit 1
mkdir -p "/${dirname}"
mount "/${dirname}" || exit 1
rsync -au "/${dirname}.bak/" "/${dirname}/" || exit 1

/etc/init.d/mysql start || exit 1

rc-update add mysql default

mysql_secure_installation <<'EOF'

n
y
y
n
y
EOF

filename="etc/mysql/configure_as_slave.sql"
configure_slave_file="$(mktemp)"
curl -sf -o "${configure_slave_file}" "${scripts}/${filename}" || exit 1

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

user="replication"
app="mysql"
type="auth"
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

user="master"
app="mysql"
type="auth"
echo "-- ${user} ${app}_${type} (decrypt)"
declare "${user}_${app}_${type}=$(decrypt_user_text "${app}_${type}" "${user}")"

sed -i -r \
-e "s|%BMOORMAN_HASH%|${bmoorman_mysql_hash}|" \
-e "s|%ECALL_HASH%|${ecall_mysql_hash}|" \
-e "s|%TPURDY_HASH%|${tpurdy_mysql_hash}|" \
-e "s|%NPETERSON_HASH%|${npeterson_mysql_hash}|" \
-e "s|%REPLICATION_AUTH%|${replication_mysql_auth}|" \
-e "s|%MONITORING_AUTH%|${monitoring_mysql_auth}|" \
-e "s|%MYTOP_AUTH%|${mytop_mysql_auth}|" \
-e "s|%MASTER_HOST%|${master%:*}|" \
-e "s|%MASTER_AUTH%|${master_mysql_auth}|" \
"${configure_slave_file}" || exit 1

mysql < "${configure_slave_file}" || exit 1

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

filename="usr/lib64/nagios/plugins/custom/check_mysql_slave"
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

filename="usr/local/lib64/mysql/watch_mysql_slave.php"
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

filename="etc/init.d/watch-mysql-slave"
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
-e "\|^\s+param\s+get_master\s+\{$|,\|^\s+\}$|s|False|True|" \
-e "\|^\s+param\s+get_slave\s+\{$|,\|^\s+\}$|s|False|True|" \
"/${filename}"

nrpe_file="$(mktemp)"
cat <<'EOF'>"${nrpe_file}"

command[check_mysqld]=/usr/lib64/nagios/plugins/check_procs -c 1: -C mysqld -a /usr/sbin/mysqld
command[check_mysql_connections]=/usr/lib64/nagios/plugins/custom/check_mysql_connections
command[check_mysql_disk]=/usr/lib64/nagios/plugins/check_disk -w 20% -c 10% -p /var/lib/mysql
command[check_mysql_slave]=/usr/lib64/nagios/plugins/custom/check_mysql_slave
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
-e "\|^cluster\s+\{$|,\|^\}$|s|(\s+name\s+\=\s+)\".*\"|\1\"Database\"|" \
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
