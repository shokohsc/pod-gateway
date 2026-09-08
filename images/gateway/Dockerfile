FROM openvpn/openvpn:3
RUN apk add --no-cache nftables ca-certificates curl
COPY killswitch.sh /usr/local/bin/killswitch.sh
RUN chmod +x /usr/local/bin/killswitch.sh
ENTRYPOINT ["/usr/local/bin/killswitch.sh"]
