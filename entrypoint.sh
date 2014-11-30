#!/bin/bash
#
# ENTRYPOINT script for "WORDPRESS" Service
#
#set -eux

## Compruebo que se ha hecho el Link:
#
#
if [ -z "${MYSQL_PORT_3306_TCP}" ]; then
	echo >&2 "error: falta la variable MYSQL_PORT_3306_TCP"
	echo >&2 "  Olvidaste --link un_contenedor_mysql:mysql ?"
	exit 1
fi
#  La dirección IP del HOST donde reside MySQL se calcula automáticamente
mysqlLink="${MYSQL_PORT_3306_TCP#tcp://}"
mysqlHost=${mysqlLink%%:*}
mysqlPort=${mysqlLink##*:}

## Conseguir la password de root desde el Link con el contenedor MySQL
#
#  Tiene que estar hecho el Link con el contenedor MySQL y desde él
#  averiguo la contraseña de root (MYSQL_ENV_MYSQL_ROOT_PASSWORD)
#
: ${SQL_ROOT:="root"}
if [ "${SQL_ROOT}" = "root" ]; then
	: ${SQL_ROOT_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
fi
if [ -z "${SQL_ROOT_PASSWORD}" ]; then
	echo >&2 "error: falta la variable MYSQL_ROOT_PASSWORD"
	exit 1
fi

## if we're linked to MySQL, and we're using the root user, and our linked
## container has a default "root" password set up and passed through... :)
#: ${WORDPRESS_DB_USER:=root}
#if [ "$WORDPRESS_DB_USER" = 'root' ]; then
#	: ${WORDPRESS_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
#fi
#: ${WORDPRESS_DB_NAME:=wordpress}

#if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
#	echo >&2 'error: missing required WORDPRESS_DB_PASSWORD environment variable'
#	echo >&2 '  Did you forget to -e WORDPRESS_DB_PASSWORD=... ?'
#	echo >&2
#	echo >&2 '  (Also of interest might be WORDPRESS_DB_USER and WORDPRESS_DB_NAME.)'
#	exit 1
#fi

## Variables para crear la BD del servicio
#
if [ -z "${SERVICE_DB_USER}" ]; then
	echo >&2 "error: falta la variable SERVICE_DB_USER"
	exit 1
fi
if [ -z "${SERVICE_DB_PASS}" ]; then
	echo >&2 "error: falta la variable SERVICE_DB_PASS"
	exit 1
fi
if [ -z "${SERVICE_DB_NAME}" ]; then
	echo >&2 "error: falta la variable SERVICE_DB_NAME"
	exit 1
fi

echo >&2 "Tengo todas las variables"
echo >&2 "SERVICE_DB_USER: ${SERVICE_DB_USER}"
echo >&2 "SERVICE_DB_PASS: ${SERVICE_DB_PASS}"
echo >&2 "SERVICE_DB_NAME: ${SERVICE_DB_NAME}"
echo >&2 "SQL_ROOT: ${SQL_ROOT}"
echo >&2 "SQL_ROOT_PASSWORD: ${SQL_ROOT_PASSWORD}"
echo >&2 "mysqlHost: ${mysqlHost}"
echo >&2 "mysqlPort: ${mysqlPort}"
echo >&2 "-----------------------------------------------------------"


## Instalo WordPress si no estaba ya instalado
#
if ! [ -e index.php -a -e wp-includes/version.php ]; then
	echo >&2 "WordPress not found in $(pwd) - copying now..."
	if [ "$(ls -A)" ]; then
		echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
		( set -x; ls -A; sleep 10 )
	fi
	rsync --archive --one-file-system --quiet /usr/src/wordpress/ ./
	echo >&2 "Complete! WordPress has been successfully copied to $(pwd)"
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
	echo >&2 "He instalado wordpress"
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

set_config 'DB_HOST' "${mysqlLink}"
set_config 'DB_USER' "${SERVICE_DB_USER}"
set_config 'DB_PASSWORD' "${SERVICE_DB_PASS}"
set_config 'DB_NAME' "${SERVICE_DB_NAME}"

# allow any of these "Authentication Unique Keys and Salts." to be specified via
# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
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
		# if not specified, let's generate a random value
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
TERM=dumb php -- "${mysqlLink}" "${SQL_ROOT}" "${SQL_ROOT_PASSWORD}" "${SERVICE_DB_NAME}" "${SERVICE_DB_USER}" "${SERVICE_DB_PASS}" <<'EOPHP'
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
// argv[4] : SERVICE_DB_NAME	--> Nombre de la base de datos
// argv[5] : SERVICE_DB_USER	--> Usuario a crear
// argv[6] : SERVICE_DB_PASS	--> Contraseña de dicho usuario
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

## Ejecuto el comando que me pasan
#
#
exec "$@"
