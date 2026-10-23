# Application service on the N6 data network (scenario-b-nginx, 10.20.6.20:80)
FROM nginx:1.27-alpine

COPY default.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

# 1 MiB object used for transfer-completion-time measurements
RUN mkdir -p /usr/share/nginx/html/files \
 && head -c 1048576 /dev/urandom > /usr/share/nginx/html/files/1M.bin

EXPOSE 80
