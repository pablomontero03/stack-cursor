# Servidor openedx (135.119.204.153)

Fuente de verdad operativa para este servidor, gestionado por
`.kiro/skills/manage-linux-servers/SKILL.md`. No contiene contraseñas,
tokens ni ningún secreto — solo inventario, checklists y hallazgos
sanitizados.

## Datos del servidor

| Campo | Valor |
|---|---|
| IP | `135.119.204.153` |
| Puerto | `22` |
| Usuario | `adminedx` |
| Hostname real | `VM` |
| Finalidad | Open edX |

## Configuración SSH local requerida

```sshconfig
Host openedx
    HostName 135.119.204.153
    Port 22
    User adminedx
    IdentityFile D:/Proyectos/automation/env/keyopenedx.pem
```

**Excepción conocida y aceptada (2026-09-08):** a diferencia de los demás
servidores de este dominio, la clave privada de `openedx` vive en
`env/keyopenedx.pem`, dentro de este repositorio, en vez de
`%USERPROFILE%\.ssh\`. El usuario decidió explícitamente dejarla ahí. El
archivo está sin trackear por git (`??`) pero el `.gitignore` del repo no
excluye nada — riesgo conocido, no corregido automáticamente por decisión
del usuario. Ver `.kiro/steering/linux-servers/security.md`.

## Servicios conocidos

- **Open edX** — instalación activa, todavía no inventariada en detalle
  (versión, forma de despliegue — Tutor/Docker vs. instalación nativa).
  Se completa la primera vez que se corra el Modo 3 del skill sobre este
  servidor.

## Comandos permitidos de diagnóstico

Ver Modo 2 y Modo 3 de `.kiro/skills/manage-linux-servers/SKILL.md`.
Open edX moderno suele desplegarse con Tutor sobre Docker — confirmar con
`docker ps`/`docker compose ls` antes de asumir la forma de despliegue.

## Política de cambios

- Todo cambio de configuración, instalación/actualización o reinicio pasa
  por los Modos 4, 5 o 6 del skill, cada uno con su propia aprobación
  explícita del usuario.
- Nunca se ejecuta ninguna de las acciones de la lista de "Prohibido
  permanentemente" del skill, bajo ninguna circunstancia.
- No se asume acceso sudo para el usuario `adminedx`.
- Ver `.kiro/steering/linux-servers/authorization.md` para el detalle
  completo de qué requiere aprobación.

## Checklist de conexión (Modo 1)

- [x] Entrada `openedx` confirmada en `%USERPROFILE%\.ssh\config`.
- [x] Usuario autorizó explícitamente la conexión SSH puntual (verificación
      de las 4 claves nuevas del dominio, 2026-09-08).
- [x] Se ejecutó `ssh openedx "hostname; whoami; uname -a"` (tras aceptar
      el host key fingerprint en la primera conexión).
- [x] Hostname y usuario devueltos coinciden con lo esperado (`VM`,
      `adminedx`).

## Checklist de diagnóstico de aplicativos (Modo 3)

- [ ] Todavía no se corrió el Modo 3 sobre este servidor — pendiente de
      inventariar la instalación real de Open edX.

## Historial de hallazgos (sanitizado)

| Fecha | Hallazgo |
|---|---|
| 2026-09-08 | Conexión SSH por llave confirmada (clave preexistente en `env/keyopenedx.pem`). Hostname real: `VM`. Ubuntu 20.04, kernel Azure `5.15.0-1089-azure`. |
