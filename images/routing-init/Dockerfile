FROM alpine:3.20
RUN apk add --no-cache nftables
COPY --chmod=755 redirect.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/redirect.sh"]
