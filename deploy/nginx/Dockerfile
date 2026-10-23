# Application server image for Scenario A.
# Content is baked into the image so that response times do not depend on a host bind mount.
FROM nginx:1.27-alpine

COPY default.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/

# 1 MiB object used for transfer-completion-time measurements
RUN mkdir -p /usr/share/nginx/html/files \
 && head -c 1048576 /dev/urandom > /usr/share/nginx/html/files/1M.bin

EXPOSE 8080
