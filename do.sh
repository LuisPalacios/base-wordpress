#!/bin/bash
#
# Punto de entrada para el servicio WordPress
#
# Activar el debug de este script:
# set -eux
#

##################################################################
#
# main
#
##################################################################

# Averiguar si necesito configurar por primera vez
#
CONFIG_DONE="/.config_wordpress_done"
NECESITA_PRIMER_CONFIG="si"
if [ -f ${CONFIG_DONE} ] ; then
    NECESITA_PRIMER_CONFIG="no"
fi


##################################################################
#
# PREPARAR timezone
#
##################################################################
# Workaround para el Timezone, en vez de montar el fichero en modo read-only:
# 1) En el DOCKERFILE
#    RUN mkdir -p /config/tz && mv /etc/timezone /config/tz/ && ln -s /config/tz/timezone /etc/
# 2) En el Script entrypoint:
if [ -d '/config/tz' ]; then
    dpkg-reconfigure -f noninteractive tzdata
    echo "Hora actual: `date`"
fi
# 3) Al arrancar el contenedor, montar el volumen, a contiuación un ejemplo:
#     /Apps/data/tz:/config/tz
# 4) Localizar la configuración:
#     echo "Europe/Madrid" > /Apps/data/tz/timezone

##################################################################
#
# VARIABLES OBLIGATORIAS
#
##################################################################


## Servidor:Puerto por el que conectar con el servidor MYSQL
#
if [ -z "${MYSQL_LINK}" ]; then
	echo >&2 "error: falta el Servidor:Puerto del servidor MYSQL: MYSQL_LINK"
	exit 1
fi
mysqlHost=${MYSQL_LINK%%:*}
mysqlPort=${MYSQL_LINK##*:}

## Contraseña del usuario root en MySQL Server
#
if [ -z "${SQL_ROOT_PASSWORD}" ]; then
	echo >&2 "error: falta la contraseña de root para MYSQL: SQL_ROOT_PASSWORD"
	exit 1
fi

## Servidor:Puerto por el que escucha el agregador de Logs (fluentd)
#
if [ -z "${FLUENTD_LINK}" ]; then
	echo >&2 "error: falta el Servidor:Puerto por el que escucha fluentd, variable: FLUENTD_LINK"
	exit 1
fi
fluentdHost=${FLUENTD_LINK%%:*}
fluentdPort=${FLUENTD_LINK##*:}


## Variables para crear la BD del servicio
#
if [ -z "${WP_DB_USER}" ]; then
	echo >&2 "error: falta la variable WP_DB_USER"
	exit 1
fi
if [ -z "${WP_DB_PASS}" ]; then
	echo >&2 "error: falta la variable WP_DB_PASS"
	exit 1
fi
if [ -z "${WP_DB_NAME}" ]; then
	echo >&2 "error: falta la variable WP_DB_NAME"
	exit 1
fi

##################################################################
#
# PREPARAR EL CONTAINER POR PRIMERA VEZ
#
##################################################################

# Cambio al directorio raiz
cd /var/www/html
 
# Necesito configurar por primera vez?
#
if [ ${NECESITA_PRIMER_CONFIG} = "si" ] ; then


	############
	#
	# Supervisor
	# 
	############
	cat > /etc/supervisor/conf.d/supervisord.conf <<EOF
[unix_http_server]
file=/var/run/supervisor.sock 					; path to your socket file

[inet_http_server]
port = 0.0.0.0:9001								; allow to connect from web browser

[supervisord]
logfile=/var/log/supervisor/supervisord.log 	; supervisord log file
logfile_maxbytes=50MB 							; maximum size of logfile before rotation
logfile_backups=10 								; number of backed up logfiles
loglevel=error 									; info, debug, warn, trace
pidfile=/var/run/supervisord.pid 				; pidfile location
minfds=1024 									; number of startup file descriptors
minprocs=200 									; number of process descriptors
user=root 										; default user
childlogdir=/var/log/supervisor/ 				; where child log files will live

nodaemon=false 									; run supervisord as a daemon when debugging
;nodaemon=true 									; run supervisord interactively
 
[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
 
[supervisorctl]
serverurl=unix:///var/run/supervisor.sock		; use a unix:// URL for a unix socket 

[program:apache]
process_name = apache
directory = /var/www/html
command = /usr/sbin/apache2ctl -D FOREGROUND
startsecs = 0
autorestart = false

[program:rsyslog]
process_name = rsyslogd
command=/usr/sbin/rsyslogd -n
startsecs = 0
autorestart = true

#
# DESCOMENTAR PARA DEBUG o SI QUIERES SSHD
#
#[program:sshd]
#process_name = sshd
#command=/usr/sbin/sshd -D
#startsecs = 0
#autorestart = true

EOF
	
	############
	#
	# Configurar rsyslogd para que envíe logs a un agregador remoto
	#
	############

    cat > /etc/rsyslog.conf <<EOFRSYSLOG
\$LocalHostName wordpress
\$ModLoad imuxsock # provides support for local system logging
#\$ModLoad imklog   # provides kernel logging support
#\$ModLoad immark  # provides --MARK-- message capability

# provides UDP syslog reception
#\$ModLoad imudp
#\$UDPServerRun 514

# provides TCP syslog reception
#\$ModLoad imtcp
#\$InputTCPServerRun 514

# Activar para debug interactivo
#
#\$DebugFile /var/log/rsyslogdebug.log
#\$DebugLevel 2

\$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat

\$FileOwner root
\$FileGroup adm
\$FileCreateMode 0640
\$DirCreateMode 0755
\$Umask 0022

#\$WorkDirectory /var/spool/rsyslog
#\$IncludeConfig /etc/rsyslog.d/*.conf

# Dirección del Host:Puerto agregador de Log's con Fluentd
#
*.* @@${fluentdHost}:${fluentdPort}

# Activar para debug interactivo
#
#*.* /var/log/syslog

EOFRSYSLOG

	############
	#
	# wordpress
	#
	############

	## Instalo WordPress si no estaba ya instalado
	#
	if ! [ -e index.php -a -e wp-includes/version.php ]; then
		echo >&2 "WordPress no está instalado así que lo copio ahora..."
		rsync --archive --one-file-system --quiet /usr/src/wordpress/ ./
		echo >&2 "WordPress se ha copiado en $(pwd)"
		if [ ! -e .htaccess ]; then
			cat > .htaccess <<-'EOF'
				RewriteEngine On
				RewriteBase /
				RewriteRule ^index\.php$ - [L]
				RewriteCond %{REQUEST_FILENAME} !-f
				RewriteCond %{REQUEST_FILENAME} !-d
				RewriteRule . /index.php [L]
			EOF
		fi
		echo >&2 "-----------------------------------------------------------"
	fi

	## Modifico el fichero wp-config.php
	#
	if [ ! -e wp-config.php ]; then
		awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wp-config-sample.php > wp-config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}

EOPHP
	fi

set_config() {
	key="$1"
	value="$2"
	php_escaped_value="$(php -r 'var_export($argv[1]);' "$value")"
	sed_escaped_value="$(echo "$php_escaped_value" | sed 's/[\/&]/\\&/g')"
	sed -ri "s/((['\"])$key\2\s*,\s*)(['\"]).*\3/\1$sed_escaped_value/" wp-config.php
}

	set_config 'DB_HOST' "${MYSQL_LINK}"
	set_config 'DB_USER' "${WP_DB_USER}"
	set_config 'DB_PASSWORD' "${WP_DB_PASS}"
	set_config 'DB_NAME' "${WP_DB_NAME}"

# Permito que cualquiera de las siguiente "Authentication Unique Keys and Salts." puedan
# especificarse a través de las variables de entorno con prefijo "WORDPRESS_" como por 
# ejemplo "WORDPRESS_AUTH_KEY"
UNIQUES=(
	AUTH_KEY
	SECURE_AUTH_KEY
	LOGGED_IN_KEY
	NONCE_KEY
	AUTH_SALT
	SECURE_AUTH_SALT
	LOGGED_IN_SALT
	NONCE_SALT
)
	for unique in "${UNIQUES[@]}"; do
		eval unique_value=\$WORDPRESS_$unique
		if [ "$unique_value" ]; then
			set_config "$unique" "$unique_value"
		else
			set_config "$unique" "$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
		fi
	done

	echo >&2 "He modificado el fichero wp-config.php"
	echo >&2 "-----------------------------------------------------------"

	## Si no existe, creo la base de datos en el servidor MySQL, notar
	#  que debemos tener las variables que indican el nombre de la DB, 
	#  y el usuario/contraseña
	#

	# Ejecuto la creación de la base de datos 
	#
	TERM=dumb php -- "${MYSQL_LINK}" "root" "${SQL_ROOT_PASSWORD}" "${WP_DB_NAME}" "${WP_DB_USER}" "${WP_DB_PASS}" <<'EOPHP'
<?php
////
//
// docker_sql.php
//
// Gestor de creación de la base de datos, usuario y contraseña.
// Si ya existe la base de datos entonces no se hace nada.
//
// Argumentos que se esperan: 
//
// argv[1] : Servidor MySQL en formato X.X.X.X:PPPP
// argv[2] : SQL_ROOT 			--> "root"  Usuario root
// argv[3] : SQL_ROOTPASSWORD	--> "<contraseña_de_root>"
// argv[4] : WP_DB_NAME         --> Nombre de la base de datos
// argv[5] : WP_DB_USER         --> Usuario a crear
// argv[6] : WP_DB_PASS         --> Contraseña de dicho usuario
//
// Ejemplo: 
//   php -f sql_test.php 192.168.1.245:3306 root rootpass mi_db mi_user mi_user_pass
//
// Autor: Luis Palacios (Nov 2014)
//

// Consigo la direccio IP y el puerto
list($host, $port) = explode(':', $argv[1], 2);

// Conecto con el servidor MySQL como root
$mysql = new mysqli($host, $argv[2], $argv[3], '', (int)$port);
if ($mysql->connect_error) {
   file_put_contents('php://stderr', '*** MySQL *** | MySQL - Error de conexión: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
   exit(1);
} else {
	printf("*** MySQL *** | MySQL Server: %s - La conexión ha sido un éxito\n", $mysql->real_escape_string($host) ); 
}

// Informo sobre la existencia de la base de datos

if ( $resultado = $mysql->query('SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME ="' . $mysql->real_escape_string($argv[4]) . '"') ) {
 if( mysqli_num_rows($resultado)>=1) {
	printf("*** MySQL *** | La base de datos '%s' ya existe, termino la ejecución\n", $mysql->real_escape_string($argv[4]) ); 
	exit(0);
 } else {
	printf("*** MySQL *** | La base de datos '%s' NO existe, voy a crearla\n", $mysql->real_escape_string($argv[4]) ); 
 }
}

// Creo la base de datos si no existia 
if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($argv[4]) . '`')) {
	file_put_contents('php://stderr', '*** MySQL *** | MySQL - Error de creación de la base de datos: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

// Doble comprobación, de que efectivamente existe la base de datos
if ( $resultado = $mysql->query('SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME ="' . $mysql->real_escape_string($argv[4]) . '"') ) {
 if( !mysqli_num_rows($resultado)>=1) {
	file_put_contents('php://stderr', '*** MySQL *** | La base de datos no existe, no puedo seguir, error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
 }
}

// Selecciono la base de datos
$mysql->select_db( 'mysql' ) or die('*** MySQL *** | No se pudo seleccionar la base de datos mysql');

// Averiguo
if ( $resultado = $mysql->query('SELECT User FROM user WHERE User="' . $mysql->real_escape_string($argv[5]) . '"') ) {
 if( !mysqli_num_rows($resultado)>=1) {

 	// No existe, lo creo
	printf("*** MySQL *** | El usuario '%s' no existe, voy a crearlo\n", $mysql->real_escape_string($argv[5]) ); 
	if (!$mysql->query('CREATE USER "' . $mysql->real_escape_string($argv[5]) . '"@"%" IDENTIFIED BY "' . $mysql->real_escape_string($argv[6]) . '"')) {
		file_put_contents('php://stderr', '*** MySQL *** | MySQL - Error al intentar crear el usuario: ' . $mysql->error . "\n");
		$mysql->close();
		exit(1);
	} else {
		printf("*** MySQL *** | La creación del usuario '%s' fue un éxito\n", $mysql->real_escape_string($argv[5]) ); 
	}
  }  else {
	printf("*** MySQL *** | El usuario '%s' ya existe\n", $mysql->real_escape_string($argv[5]) ); 
  }
	
  // Asigno al propietario todos los privilegios sobre la nueva BD
  if (!$mysql->query('GRANT ALL ON ' . $mysql->real_escape_string($argv[4]) . '.* TO "' . $mysql->real_escape_string($argv[5]) . '"@"%"')) {
	file_put_contents('php://stderr', '*** MySQL *** | MySQL - Error al intentar darle todos los permisos al usuario: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
  } else {
	printf("*** MySQL *** | Asignados con éxito los permisos para el usuario '%s' en la base de datos '%s'\n", $mysql->real_escape_string($argv[5]) , $mysql->real_escape_string($argv[4]) ); 
  }
	
} else {
	file_put_contents('php://stderr', '*** MySQL *** | La búsqueda del usuario devolvió error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

$mysql->close();
exit(0);

?>
EOPHP

	echo >&2 "Verificada la BD del servicio y sus permisos"
	echo >&2 "-----------------------------------------------------------"


	## Cambio los permisos al directorio de wordpress
	#
	#
	chown -R www-data:www-data .

    #
    # Creo el fichero de control para que el resto de 
    # ejecuciones no realice la primera configuración
    > ${CONFIG_DONE}

fi


##################################################################
#
# EJECUCIÓN DEL COMANDO SOLICITADO
#
##################################################################
#
exec "$@"
