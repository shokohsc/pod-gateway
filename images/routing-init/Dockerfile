FROM alpine:3.20
RUN apk add --no-cache nftables
COPY redirect.sh /usr/local/bin/redirect.sh
RUN chmod +x /usr/local/bin/redirect.sh
ENTRYPOINT ["/usr/local/bin/redirect.sh"]
