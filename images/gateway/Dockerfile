FROM alpine:3.20
RUN apk add --no-cache openvpn nftables ca-certificates
COPY --chmod=755 killswitch.sh fetchconfig.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/killswitch.sh"]
