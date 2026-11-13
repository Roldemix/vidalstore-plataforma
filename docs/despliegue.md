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

La infraestructura Azure de la evidencia se creó en `northcentralus` dentro
del grupo `rg-vidalstore-e2`. No hay scripts Azure versionados en este
repositorio; las órdenes siguientes permiten inspeccionar y reproducir la
configuración sin guardar credenciales:

```bash
az group show --name rg-vidalstore-e2 --output table
az vm list --resource-group rg-vidalstore-e2 \
  --show-details --query "[].[name, powerState, privateIps, publicIps]" \
  --output table
az network vnet subnet list --resource-group rg-vidalstore-e2 \
  --vnet-name vnet-vidalstore --output table
az network route-table route list --resource-group rg-vidalstore-e2 \
  --route-table-name rt-bff-gw --output table
az network nic show --resource-group rg-vidalstore-e2 \
  --name nic-gw-azure \
  --query "{ipForwarding:enableIPForwarding,privateIp:ipConfigurations[0].privateIPAddress}" \
  --output json
```

La prueba de salida del BFF debe ejecutarse desde la VM privada y debe
devolver la IP pública del gateway:

```bash
az vm run-command invoke \
  --resource-group rg-vidalstore-e2 \
  --name bff \
  --command-id RunShellScript \
  --scripts "curl --fail --silent https://api.ipify.org"
```

Antes de entregar, guardar esas salidas en el informe y desasignar las VMs
para evitar costos:

```bash
az vm deallocate --resource-group rg-vidalstore-e2 --name gw-azure bff
az vm list --resource-group rg-vidalstore-e2 \
  --show-details --query "[].[name, powerState]" --output table
```
