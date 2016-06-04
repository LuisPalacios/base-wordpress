#
# WordPress server base by Luispa, Dec 2014
#
# -----------------------------------------------------
#

# Desde donde parto...
#
FROM php:5.6-apache

#
MAINTAINER Luis Palacios <luis@luispa.com>

# Pido que el frontend de Debian no sea interactivo
ENV DEBIAN_FRONTEND noninteractive

# ------- ------- ------- ------- ------- ------- -------
# Básico
# ------- ------- ------- ------- ------- ------- -------
#
RUN apt-get update && \
    apt-get -y install locales \
                       vim \
                       supervisor \
                       wget \
                       curl 

# Preparo locales
#
RUN locale-gen es_ES.UTF-8
RUN locale-gen en_US.UTF-8
RUN dpkg-reconfigure locales

# Preparo el timezone para Madrid
#
RUN echo "Europe/Madrid" > /etc/timezone; dpkg-reconfigure -f noninteractive tzdata


# Workaround para el Timezone, en vez de montar el fichero en modo read-only:
# 1) En el DOCKERFILE
RUN mkdir -p /config/tz && mv /etc/timezone /config/tz/ && ln -s /config/tz/timezone /etc/
# 2) En el Script entrypoint:
#     if [ -d '/config/tz' ]; then
#         dpkg-reconfigure -f noninteractive tzdata
#         echo "Hora actual: `date`"
#     fi
# 3) Al arrancar el contenedor, montar el volumen, a contiuación un ejemplo:
#     /Apps/data/tz:/config/tz
# 4) Localizar la configuración:
#     echo "Europe/Madrid" > /Apps/data/tz/timezone
 
# ------- ------- ------- ------- ------- ------- -------
# WordPress
# ------- ------- ------- ------- ------- ------- -------
#
RUN apt-get update && apt-get install -y rsync && rm -r /var/lib/apt/lists/*

RUN a2enmod rewrite expires headers

# Instalo las extensiones PHP que necesito
# install the PHP extensions we need
RUN apt-get update && apt-get install -y libpng12-dev libjpeg-dev && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr \
    && docker-php-ext-install gd mysqli opcache

# Incremento el tamaño máximo de fichero que se permite subir
RUN touch /usr/local/etc/php/conf.d/uploads.ini \
    && echo "upload_max_filesize = 30M;" >> /usr/local/etc/php/conf.d/uploads.ini

ENV WORDPRESS_VERSION 4.5.2
ENV WORDPRESS_SHA1 bab94003a5d2285f6ae76407e7b1bbb75382c36e

# Los tarballs upstream incluyen ./wordpress/ por lo que quedan en /usr/src/wordpress
RUN curl -o wordpress.tar.gz -SL https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz \
    && echo "$WORDPRESS_SHA1 *wordpress.tar.gz" | sha1sum -c - \
    && tar -xzf wordpress.tar.gz -C /usr/src/ \
    && rm wordpress.tar.gz \
    && chown -R www-data:www-data /usr/src/wordpress
	     
# Preparo Apache
RUN echo "ServerName www" >> /etc/apache2/apache2.conf
RUN echo "IncludeOptional sites-enabled/*.conf" >> /etc/apache2/apache2.conf
ADD ./000-default.conf /etc/apache2/sites-available/000-default.conf
RUN a2ensite 000-default

# ------- ------- ------- ------- ------- ------- -------
# rsyslog
# ------- ------- ------- ------- ------- ------- -------
RUN apt-get update && \
    apt-get -y install rsyslog

# ------- ------- ------- ------- ------- ------- -------
# DEBUG ( Descomentar durante debug del contenedor )
# ------- ------- ------- ------- ------- ------- -------
#
# Herramientas SSH, tcpdump y net-tools
#RUN apt-get update && \
#    apt-get -y install 	openssh-server \
#                       	tcpdump \
#                        net-tools
### Setup de SSHD
#RUN mkdir /var/run/sshd
#RUN echo 'root:docker' | chpasswd
#RUN sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config
#RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
#ENV NOTVISIBLE "in users profile"
#RUN echo "export VISIBLE=now" >> /etc/profile

## Script que uso a menudo durante las pruebas. Es como "cat" pero elimina líneas de comentarios
RUN echo "grep -vh '^[[:space:]]*#' \"\$@\" | grep -v '^//' | grep -v '^;' | grep -v '^\$' | grep -v '^\!' | grep -v '^--'" > /usr/bin/confcat
RUN chmod 755 /usr/bin/confcat

#-----------------------------------------------------------------------------------

# Ejecutar siempre al arrancar el contenedor este script
#
ADD do.sh /do.sh
RUN chmod +x /do.sh
ENTRYPOINT ["/do.sh"]

#
# Si no se especifica nada se ejecutará lo siguiente: 
#
CMD ["/usr/bin/supervisord", "-n -c /etc/supervisor/supervisord.conf"]

