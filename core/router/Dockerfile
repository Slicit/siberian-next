FROM nginx:1.27-alpine

RUN rm -f /etc/nginx/conf.d/default.conf && mkdir -p /etc/nginx/conf.d/modules

COPY core/router/nginx/nginx.conf /etc/nginx/nginx.conf
COPY core/router/nginx/templates/00-core.conf.template /etc/nginx/templates/00-core.conf.template

# The module template is not rendered at start. The Orchestrator renders it per
# module and drops the result into conf.d/modules, then reloads.
COPY lib/router/module.conf.template /etc/nginx/siberian/module.conf.template
COPY core/router/nginx/siberian/internal_headers.conf /etc/nginx/siberian/internal_headers.conf
COPY core/router/nginx/siberian/forwarded_headers.conf /etc/nginx/siberian/forwarded_headers.conf

EXPOSE 80 443
