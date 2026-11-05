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

No se deben guardar credenciales AWS en el repositorio.
