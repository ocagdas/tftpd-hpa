# tftpd-hpa
tftpd-hpa server based on alpine

# docker build
```
docker build -f ./Dockerfile-tftpd-hpa -t zmart/tftpd-hpa .
```

# docker run
You canl also put the specific ip address you want to map to infront of the port mapping as '192.168.2.1:'. Also make sure that /tftpboot exists on the host.
```
docker run --rm --net host -dit -p 69:69/udp --name=tftpd-hpa -v /tftpboot:/var/tftpboot:ro zmart/tftpd-hpa:latest
```
