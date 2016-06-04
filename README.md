# Introducción

Este repositorio alberga un *contenedor Docker* para montar WordPress, está automatizado en el Registry Hub de Docker [luispa/base-wordpress](https://registry.hub.docker.com/u/luispa/base-wordpress/) conectado con el proyecto en [GitHub base-wordpress](https://github.com/LuisPalacios/base-wordpress)

Consulta este [apunte técnico sobre varios servicios en contenedores Docker](http://www.luispa.com/?p=172) para acceder a otros contenedores Docker y sus fuentes en GitHub.

## Ficheros

* **Dockerfile**: Para crear la base de servicio.
* **do.sh**: Para arrancar el contenedor creado con esta imagen.

## Instalación de la imagen

### desde Docker

Para usar esta imagen desde el registry de docker hub

    totobo ~ $ docker pull luispa/base-wordpress

### manualmente

Si prefieres crear la imagen de forma manual en tu sistema, primero debes clonarla desde Github para luego ejecutar el build

    $ git clone https://github.com/LuisPalacios/base-wordpress.git
    $ docker build -t luispa/base-wordpress ./



# Ejecución

## Arrancar manualmente

Puedes ejecutar "manulamente" el contenedor, muy útil para hacer pruebas. Aquí te dejo un "ejemplo", aunque dependerá de tu entorno...:

	run --rm -t -i --name servicioweb_wordpress_1 -e WP_DB_USER="usuario" -e WP_DB_PASS="pase" -e WP_DB_NAME="basededatos" -e MYSQL_LINK="tuservidor.dominio.com:33001" -e SQL_ROOT_PASSWORD="password_root" -e FLUENTD_LINK="tuservidor.dominio.com:24224" --expose=80 -v /Apps/data/web/www.luispa.com/wordpress:/var/www/html luispa/base-wordpress /bin/bash
	 

## Arrancar con "fig"

Si por el contrario prefieres automatizarlo con el programa [fig](http://www.fig.sh/index.html) y que arranquen varios contenedores entonces te recomiendo que eches un ojo al [servicio-web](https://github.com/LuisPalacios/servicio-web) que he dejado en GitHub, ahí encontrás un ejemplo sobre cómo hacerlo.

    $ git clone https://github.com/LuisPalacios/servicio-web.git
    :
    $ mv fig-template.yml fig.yml
    :
    $ fig up -d



# Personalización

## Variables

Utilizo varias variables para poder personalizar la copia de WordPress al arrancarla: 

    WP_DB_USER:         Usuario de la BD de WordPress en MySQL
    WP_DB_PASS:         Password de dicho usuario
    WP_DB_NAME:         Nombre de la BD de WordPress en MySQL
    MYSQL_LINK:         Dirección del servidor MySQL (srv.dom.com:puerto)
    SQL_ROOT_PASSWORD:  Password de root en MySQL para poder crear la DB si hace falta
    FLUENTD_LINK:       Dirección del servidor de recepción de Logs (srv.dom.com:puerto)


## Volúmenes

Es importante que prepares un directorio persistente para tus datos de WordPress, en mi caso lo he dejado así a modo de ejemplo:

  - "/Apps/data/web/www.luispa.com/wordpress:/var/www/html"

Directorio persistente para configurar el Timezone. Crear el directorio /Apps/data/tz y dentro de él crear el fichero timezone. Luego montarlo con -v o con fig.yml

    Montar:
       "/Apps/data/tz:/config/tz"  
    Preparar: 
       $ echo "Europe/Madrid" > /config/tz/timezone

