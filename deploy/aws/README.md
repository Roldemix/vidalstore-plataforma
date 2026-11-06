# AWS

La cuenta de Learner Lab se valida con:

```bash
aws sts get-caller-identity
```

La red base se crea en `us-east-1` con:

```bash
bash deploy/aws/crear-infraestructura.sh
```

El script crea únicamente la VPC, subredes, tablas de rutas, Internet Gateway y
security group interno. No abre SSH ni lanza instancias automáticamente. Las
instancias deben usar `LabInstanceProfile` y administrarse mediante Session
Manager.

La arquitectura prevista está documentada en [red.md](../../docs/red.md).

## Despliegue de EC2

Con la red creada, el despliegue completo crea un NAT Gateway, agrega la salida
de las subredes privadas y lanza las siete instancias `t3.micro` descritas en
[red.md](../../docs/red.md). Todas usan `LabInstanceProfile`, no abren SSH y
se preparan con Docker y Git:

```bash
export VPC_ID=vpc-...
export PUBLIC_SUBNET=subnet-...
export APP_SUBNET=subnet-...
export DATA_SUBNET_A=subnet-...
export DATA_SUBNET_B=subnet-...
export SECURITY_GROUP=sg-...
bash deploy/aws/desplegar-ec2.sh
```

El script es idempotente para el NAT y las instancias existentes. El NAT
Gateway genera costos mientras permanezca activo.

## Verificación de permisos

La prueba oficial crea recursos temporales con el prefijo `ep3-permisos` y los
elimina al finalizar, incluso si una comprobación falla. Desde Git Bash:

```bash
export MSYS_NO_PATHCONV=1
bash deploy/aws/verificar-permisos.sh
```

El resultado queda en `deploy/aws/permisos.txt`. En Windows, el verificador
detecta automáticamente el Session Manager Plugin instalado en su ruta estándar
aunque no esté agregado al `PATH`.

No se deben guardar credenciales AWS en el repositorio.
