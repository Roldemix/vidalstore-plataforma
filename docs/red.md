# Diseño de red AWS

## Alcance

La región objetivo es `us-east-1`. La VPC usa `10.0.0.0/16` y separa el tráfico
público, de aplicación y de datos.

| Segmento | CIDR | Zona | Uso |
|---|---|---|---|
| Pública | `10.0.1.0/24` | `us-east-1a` | gateway y salida controlada |
| Aplicación | `10.0.11.0/24` | `us-east-1a` | catálogo, licencias y eventos |
| Datos A | `10.0.21.0/24` | `us-east-1a` | Kafka/RabbitMQ y PostgreSQL |
| Datos B | `10.0.22.0/24` | `us-east-1b` | segundo nodo de datos y tolerancia de zona |

La subred pública tiene ruta al Internet Gateway. Las subredes de aplicación y
datos no reciben tráfico entrante desde Internet. No se abre el puerto 22:
las máquinas se administran mediante AWS Systems Manager usando
`LabInstanceProfile`.

## Componentes previstos

| Nombre | Segmento | Servicio |
|---|---|---|
| `gw-aws` | Pública | gateway/Caddy |
| `servicios` | Aplicación | gateway, BFF, catálogo, licencias y eventos |
| `gestion` | Aplicación | administración y Kafka UI |
| `mq-1` | Datos A | Kafka controller/broker y RabbitMQ |
| `mq-2` | Datos B | Kafka controller/broker y RabbitMQ |
| `mq-3` | Datos A | Kafka controller/broker y RabbitMQ |
| `postgres` | Datos A | PostgreSQL |

Los tamaños deben justificarse con la cuota disponible del Learner Lab. El
script de red no crea NAT Gateway ni EC2 automáticamente para evitar costos
accidentales; esos recursos se habilitan como una fase separada y etiquetada.
