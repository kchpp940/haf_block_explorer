#!/bin/sh

# Default value for HAFBE_API_BASE_PATH
HAFBE_API_BASE_PATH="${HAFBE_API_BASE_PATH:-/hafbe-api}"

# Ensure base path starts with / and has no trailing /
HAFBE_API_BASE_PATH="/$(echo "$HAFBE_API_BASE_PATH" | sed 's|^/||;s|/$||')"

# Default value for REWRITE_LOG is off, unless explicitly set to 'on'
if [ "$REWRITE_LOG" = "on" ]; then
    REWRITE_LOG="rewrite_log on;"
else
    REWRITE_LOG="# rewrite_log off;"
fi

# Use sed to replace placeholders in the nginx template file
sed "s|\${REWRITE_LOG}|$REWRITE_LOG|g; s|\${HAFBE_API_BASE_PATH}|$HAFBE_API_BASE_PATH|g" \
    /usr/local/openresty/nginx/conf/nginx.conf.template > /usr/local/openresty/nginx/conf/nginx.conf

# Also replace placeholders in rewrite_rules.conf
sed "s|\${HAFBE_API_BASE_PATH}|$HAFBE_API_BASE_PATH|g" \
    /usr/local/openresty/nginx/conf/rewrite_rules.conf > /usr/local/openresty/nginx/conf/rewrite_rules.conf.tmp
mv /usr/local/openresty/nginx/conf/rewrite_rules.conf.tmp /usr/local/openresty/nginx/conf/rewrite_rules.conf

# Start nginx
/usr/local/openresty/bin/openresty -g 'daemon off;'
