# Diseño de red

La entrega usa dos nubes con rangos que no se solapan. Solo el borde de Azure
tiene dirección pública; el resto se alcanza por la ruta privada entre nubes.

## AWS (`us-east-1`)

VPC `10.0.0.0/16`, sin NAT para el tráfico de aplicación salvo el que ya
necesita Docker para descargar imágenes.

| Segmento | CIDR | Zona | Uso |
|---|---|---|---|
| Pública | `10.0.1.0/24` | `us-east-1a` | `gw-aws` y salida a Internet |
| Aplicación | `10.0.11.0/24` | `us-east-1a` | `servicios` y `gestion` |
| Datos A | `10.0.21.0/24` | `us-east-1a` | `mq-1`, `mq-3` y `datos` |
| Datos B | `10.0.22.0/24` | `us-east-1b` | `mq-2` |

| Nombre | IP privada | Rol | Puertos publicados |
|---|---|---|---|
| `gw-aws` | `10.0.1.10` | Caddy con TLS interno | 443 (solo desde `gw-azure`) |
| `servicios` | `10.0.11.10` | gateway, catálogo, licencias, eventos | 8080, 3001, 3002, 3010 dentro del SG |
| `gestion` | `10.0.11.20` | admin y Kafka UI | `127.0.0.1` únicamente |
| `mq-1` | `10.0.21.10` | Kafka y RabbitMQ | 9092, 5672, 15672 dentro del SG |
| `mq-2` | `10.0.22.10` | Kafka y RabbitMQ | dentro del SG |
| `mq-3` | `10.0.21.11` | Kafka y RabbitMQ | dentro del SG |
| `datos` | `10.0.21.20` | PostgreSQL | 5432 dentro del SG |

El Security Group se ajusta con
[`deploy/aws/permisos-e3.sh`](../deploy/aws/permisos-e3.sh): 443 para `gw-aws` y
3001/3002/3010 para los servicios, siempre desde `10.1.0.0/16` (la VNet de
Azure, que llega NATeada por `gw-azure`). No hay reglas abiertas a Internet ni
22. Las máquinas se administran con Session Manager y el perfil
`LabInstanceProfile`.

`gw-aws` recibe una IP pública automática de la subred para poder descargar
imágenes de Docker Hub, pero su Security Group solo acepta 443 desde Azure: no
es un borde alcanzable desde Internet.

## Azure (`eastus`)

VNet `10.1.0.0/16`.

| Subred | CIDR | Máquina | Rol |
|---|---|---|---|
| `snet-gw` | `10.1.1.0/24` | `gw-azure` (`10.1.1.10`) | Caddy público, frontend y HTTPS |
| `snet-bff` | `10.1.2.0/24` | `bff` (`10.1.2.10`) | BFF privado |

`gw-azure` tiene la única IP pública (estática) y el NSG `nsg-gw` abre 80 y
443. El NSG `nsg-bff` solo permite 8081 desde `10.1.1.0/24` (gw-azure) y desde
`10.0.0.0/16` (el gateway de AWS, que llega por la ruta privada). El 22 no se
abre en ninguna de las dos: se usa `az vm run-command`.

La tabla `rt-bff-gw` envía `10.0.0.0/16` (AWS) al próximo salto `10.1.1.10`
con reenvío IP habilitado en `nic-gw-azure`, que hace NAT de salida. La ruta
real entre las dos nubes (VPN o peering) es la que se dejó montada en la EP2;
si esa ruta no está activa, el BFF no alcanza `10.0.1.10`.

## Nombres y certificados

- `gw-azure` publica `<ip-publica-con-guiones>.sslip.io`. Let's Encrypt emite el
  certificado por HTTP-01 en el puerto 80.
- `gw-aws` usa `tls internal` de Caddy. Su CA se copia a `gw-azure`
  (`/opt/vidalstore/certs/aws-ca.crt`) y Caddy la usa con
  `tls_trusted_ca_certs` para validar el salto privado.

## Lo que no se abre

- 9092 de Kafka, 5672 de RabbitMQ y 5432 de PostgreSQL: solo dentro del SG de
  AWS.
- 3020 del admin y 8085 de Kafka UI: bind a `127.0.0.1` más túnel de Session
  Manager.
- 8081 del BFF: solo desde `gw-azure`.
