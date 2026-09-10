FROM alpine:3.20
RUN apk add --no-cache openvpn nftables iproute2 ca-certificates
COPY --chmod=755 killswitch.sh killswitch-close.sh killswitch-open.sh fetchconfig.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/killswitch.sh"]
