FROM alpine:3.20
RUN apk add --no-cache openvpn nftables ca-certificates curl
COPY killswitch.sh /usr/local/bin/killswitch.sh
RUN chmod +x /usr/local/bin/killswitch.sh
COPY fetchconfig.sh /usr/local/bin/fetchconfig.sh
RUN chmod +x /usr/local/bin/fetchconfig.sh
ENTRYPOINT ["/usr/local/bin/killswitch.sh"]
