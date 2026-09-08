FROM openvpn/openvpn:3
RUN apk add --no-cache nftables ca-certificates curl
COPY killswitch.sh /usr/local/bin/killswitch.sh
RUN chmod +x /usr/local/bin/killswitch.sh
COPY fetchconfig.sh /usr/local/bin/fetchconfig.sh
RUN chmod +x /usr/local/bin/fetchconfig.sh
ENTRYPOINT ["/usr/local/bin/killswitch.sh"]
