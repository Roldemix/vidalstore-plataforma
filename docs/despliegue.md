# Evidencia de despliegue

Este documento reúne comandos reproducibles. Las salidas concretas de una
ejecución deben agregarse al informe de la entrega sin guardar secretos.

## Local

```bash
bash levantar.sh
docker compose ps
docker compose exec broker-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server broker-1:19092 --describe --topic vidalstore.compras
docker compose exec broker-1 /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server broker-1:19092 --all-groups --describe
```

El panel queda en `http://localhost:4200/panel` y actualiza cada cinco
segundos. El gateway local queda en `http://localhost:8080`.

## AWS

La red se crea con `deploy/aws/crear-infraestructura.sh` y las instancias con
`deploy/aws/desplegar-ec2.sh`. Se entra mediante Session Manager; el security
group no debe tener reglas de entrada para el puerto 22.

```bash
aws ec2 describe-security-groups \
  --filters Name=ip-permission.from-port,Values=22 \
  --query "SecurityGroups[].GroupName"
aws ec2 describe-instances --filters Name=tag:Name,Values='vidalstore-*' \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,PrivateIpAddress,State.Name]" \
  --output table
```

## Azure

La red y las dos máquinas deben crearse desde scripts en `deploy/azure/`,
probarse y quedar desasignadas al entregar. Las salidas de rutas, IP privada,
proxy de salida por `gw-azure` y estado `deallocated` deben quedar en el
informe.
