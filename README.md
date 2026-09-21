# Summit Connect Madrid - Model-As-A-Service: facilitando el acceso a modelos gobernados

## Abstract

Descubre cómo Red Hat MaaS (GA) democratiza la IA empresarial. Demo en vivo: despliegue ágil de modelos, soberanía de datos e inferencia escalable. / Build with private AI at scale: use Red Hat OpenShift AI MaaS to power code assistants, MCP-driven agents, and real-time usage insights.

---

Model as a Service: acceso gobernado a modelos de IA - local y cloud - con Red Hat OpenShift AI.

Demo de 20 minutos en el estadio del Atletico de Madrid.

> **Regla de la demo**: todo lo de MaaS se hace desde la **UI de RHOAI** (`https://rh-ai.<domain>`).
> La terminal solo aparece dentro del sandbox, y alli se usa **OpenCode**, no `curl`.

## La historia

Una empresa tiene dos equipos que necesitan modelos de IA: **Desarrolladores** y **Ventas**. El CIO tiene tres prioridades:

1. **Soberania de datos**: hay un modelo local (gpt-oss-20b) en GPU propia; los datos no salen del cluster.
2. **Potencia cuando se necesita**: modelos cloud de OpenAI (gpt-5.5 y gpt-4.1) disponibles bajo demanda.
3. **Control de costes**: el cloud es caro. Solo Desarrolladores lo usa, y con limites estrictos.

La plataforma lo garantiza: nadie tiene que "portarse bien" manualmente.

## Arquitectura

```
                    ┌─────────────────────────────────────────┐
                    │            MaaS Gateway                 │
                    │   maas.apps.ocp.xxx.opentlc.com         │
                    │        POST /v1/chat/completions        │
                    └──────────┬───────────────┬──────────────┘
                               │               │
                    ┌──────────▼──────┐  ┌─────▼──────────────────┐
                    │  gpt-oss-20b    │  │  gpt-5.5 / gpt-4.1     │
                    │  (GPU local)    │  │  (OpenAI, cloud)       │
                    │  namespace: llm │  │  ns: external-models   │
                    │  vLLM en L40S   │  │  ExternalModel         │
                    └─────────────────┘  └────────────────────────┘
```

## Matriz de acceso

| Equipo | gpt-oss-20b (local) | gpt-5.5 (cloud) | gpt-4.1 (cloud, agentes) |
|--------|:-------------------:|:---------------:|:------------------------:|
| **Desarrolladores** | 50k tok/min | 2k tok/min | 20k tok/min |
| **Ventas** | 20k tok/min | Sin acceso (403) | Sin acceso (403) |
| **admin** (presentador) | 50k tok/min | 2k tok/min | 20k tok/min |

Dos modelos cloud a proposito:

- **gpt-5.5** es el modelo caro de la narrativa: limite bajo (2.000 tok/min) para que el **429** salte en
  directo con dos o tres preguntas. Se usa en el playground y por API.
- **gpt-4.1** es el que usa **OpenCode** en el sandbox. OpenCode inyecta parametros de razonamiento
  (`reasoningSummary`) para cualquier id de la familia `gpt-5` y `/v1/chat/completions` los rechaza con
  `400 Unknown parameter`. Ver [Troubleshooting](#troubleshooting).

> `admin` esta incluido a proposito: en MaaS la visibilidad de modelos va por **suscripcion + politica de
> autorizacion**, no por ser cluster-admin. Si el presentador no esta en ninguna suscripcion, la UI de MaaS
> le muestra **cero modelos**. Ver [Troubleshooting](#troubleshooting).

---

## Preparacion (antes de la demo)

### 1. GPU y plataforma MaaS (~45 min)

```bash
oc login https://api.ocp.<cluster>.opentlc.com:6443 -u admin -p <password>

# GPU MachineSet (g6e.xlarge para L40S)
cd ocp-gpu-setup && ./machine-set/gpu-machineset.sh

# MaaS + observabilidad
cd rhoai-maas-guide && ./scripts/setup-maas.sh --with-observability
```

### 2. Modelo local gpt-oss-20b

Los manifests viven en este repo (`manifests/01-models/gpt-oss-20b/`, copiados de
[rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide/tree/main/manifests/05-maas-models/gpt-oss-20b)):

```bash
oc apply -k manifests/01-models/gpt-oss-20b/llm    # LLMInferenceService (vLLM CUDA, 1 GPU)
oc apply -k manifests/01-models/gpt-oss-20b/maas   # MaaSModelRef + auth policy + suscripciones base
oc get llminferenceservice -n llm -w      # espera READY=True (~10 min, descarga modelcar 8GB)
```

### 3. Clave de OpenAI para los modelos cloud (~2 min)

Hace falta una clave de OpenAI (`sk-...`, `sk-proj-...` o de service account) con acceso a `gpt-5.5` y
`gpt-4.1`. Comprueba que la clave los tiene antes de la demo - una service account puede listar modelos
que luego no puede usar:

```bash
export OPENAI_API_KEY='sk-...'
for m in gpt-5.5 gpt-4.1; do
  echo -n "$m -> "
  curl -s -o /dev/null -w '%{http_code}\n' https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_completion_tokens\":20}"
done
# 200 en los dos
```

El secret lo crea `setup-demo.sh`. Si lo haces a mano:

```bash
oc create secret generic openai-api-key -n external-models \
  --from-literal=api-key="$OPENAI_API_KEY" --dry-run=client -o yaml | oc apply -f -
oc label secret openai-api-key -n external-models inference.llm-d.ai/ipp-managed=true --overwrite
```

### 4. Desplegar la demo (~5 min)

```bash
DEMO_PASSWORD='redhat123' OPENAI_API_KEY='sk-...' ./scripts/setup-demo.sh
```

Crea usuarios (`desarrollador-1`, `vendedor-1`), grupos, los modelos cloud, las politicas, las
suscripciones y el proyecto de cada equipo.

### 5. Sandbox con OpenCode (~10 min)

```bash
./scripts/install-openshell.sh
```

Genera la API key del sandbox **en la UI** (Gen AI studio → API keys → Create API key, ver Acto 3) y luego:

```bash
MAAS_API_KEY='sk-oai-...' ./scripts/setup-sandbox.sh
```

### 6. Kueue en los proyectos (si sale el banner)

Si el proyecto de un equipo muestra *"Kueue is disabled in this cluster"*:

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{"spec":{"dashboardConfig":{"disableKueue":false}}}'
```

Recarga **sin cache** (Cmd+Shift+R o pestaña nueva): con un F5 normal el banner sigue apareciendo.

![Proyecto sin el banner de Kueue](docs/images/16-project-kueue-banner-fixed.png)

### 7. Comprobacion previa (obligatoria)

```bash
./scripts/check-demo.sh
```

Valida de golpe: modelos Ready, presentador con suscripcion, inferencia local y cloud (con reintento por
la conexion en frio) y OpenCode dentro del sandbox contra el modelo local **y** el cloud.

---

## Guion de la demo (20 minutos)

### Acto 1 - El problema del CIO (3 min)

> "Sois el CIO. Dos equipos, dos modelos: uno local en vuestras GPUs, otro en la nube. El local es seguro
> pero limitado. El cloud es potente pero caro. Como dais acceso a cada equipo con garantias?"

Nada que clicar todavia. Solo la diapositiva.

### Acto 2 - Dos modelos, dos mundos (4 min)

**UI**: `AI hub` → `Models` → pestaña `Deployments`.

Sub-pestaña **Internal models**: el modelo local, servido con llm-d sobre GPU.

![Modelo local en el dashboard](docs/images/03-deployments-internal-gpt-oss.png)

Sub-pestaña **External models** (Tech Preview) → en el selector **Project** elige `external-models`:
aparecen `gpt-5.5` y `gpt-4.1` con su provider `openai` en estado `Ready`.

![Modelos cloud registrados](docs/images/04-deployments-external-cloud.png)

**UI**: `Gen AI studio` → `AI asset endpoints` → proyecto `sandbox-scm`. Los dos modelos, en la misma lista,
con el mismo ciclo de vida y el mismo endpoint de gateway:

![AI asset endpoints con los tres modelos](docs/images/11-ai-asset-endpoints.png)

> "Local y cloud son el mismo tipo de activo para la plataforma. La gobernanza no distingue donde corre el modelo."

### Acto 3 - Gobernanza como politica (6 min)

**UI**: `Settings` → `MaaS governance` → pestaña `Subscriptions`. Una suscripcion por equipo, con su limite:

![Suscripciones MaaS](docs/images/01-maas-governance-subscriptions.png)

Pestaña `Authorization policies`: quien puede acceder a que. `gpt-oss-20b` para todos los autenticados,
los modelos cloud solo para el grupo `scm-desarrolladores`:

![Politicas de autorizacion](docs/images/02-maas-governance-authpolicies.png)

Ahora el mismo cluster, visto por cada equipo. **Logout** y entra con el IdP `scm-demo`.

`vendedor-1` (`redhat123`) → `Gen AI studio` → `API keys` → pestaña `Subscriptions` → despliega la fila:
**un modelo**, 20.000 tok/min.

![Ventas ve un modelo](docs/images/09-ventas-subscription-1-model.png)

`desarrollador-1` (`redhat123`), misma pantalla: **tres modelos**, con 50.000 / 2.000 / 20.000 tok/min.

![Desarrolladores ve tres modelos](docs/images/05-dev-subscription-models.png)

> "Ventas ve un modelo. Desarrolladores ven dos. La misma plataforma, distintos permisos, cero configuracion
> en el cliente."

Como `desarrollador-1`, crea la API key del sandbox delante del publico:
`Create API key` → nombre `opencode-sandbox` → suscripcion `SCM - Equipo Desarrolladores`
(el dialogo muestra los modelos que la key va a poder usar) → `Expiration` 30 dias.

![Crear API key](docs/images/06-create-api-key-ui.png)

![API key creada](docs/images/07-api-key-created.png)

> "La key esta atada a la suscripcion. No es un secreto compartido con permisos infinitos: caduca, es
> revocable y solo abre los modelos de su suscripcion."

**Inferencia en vivo, sin terminal**: `Gen AI studio` → `Playground` → proyecto `Proyecto Desarrolladores`.
En `Settings` elige el modelo (`gpt-oss-20b`, `gpt-5.5` o `gpt-4.1`) y la suscripcion del equipo, y pregunta algo.
El panel muestra tokens y T/s, que es justo lo que la suscripcion esta limitando.

![Playground con el modelo cloud](docs/images/14-playground-cloud-model.png)

**Rate limiting en vivo**: en el mismo playground cambia el modelo a `gpt-5.5` y lanza dos o tres
preguntas seguidas. Con 2.000 tokens/min la suscripcion se agota enseguida y la UI devuelve el error del
gateway (`429 Too Many Requests`). Comportamiento verificado en este cluster bajando el limite a 300
tokens/min: la primera peticion devuelve `200` y de la segunda en adelante `429`.

> Para que el 429 funcione el trafico tiene que ir por la HTTPRoute que genera MaaS (la que apunta el
> `TokenRateLimitPolicy`), es decir por `POST /v1/chat/completions` con el nombre del modelo en el body.
> Comprobado: peticiones 1-11 en `200` y la 12 en `429`.

> "Nadie ha tenido que portarse bien. El equipo puede pedir lo que quiera; el gasto lo corta la plataforma."

Si prefieres verlo en numeros, `./scripts/run-demo.sh` hace rafagas por equipo y resume `200 / 429 / 403`.

### Acto 4 - El sandbox del desarrollador (6 min)

> "El desarrollador no toca YAML ni claves. Abre su agente y trabaja."

Conecta al sandbox (una sola linea, y es la unica terminal de la demo):

```bash
openshell sandbox exec --gateway scm-demo --name opencode-scm --tty -- bash -l
```

Dentro, todo con **OpenCode**. La key de MaaS ya esta inyectada en el entorno, y los dos modelos estan
declarados como providers (`local/gpt-oss-20b` y `cloud/gpt-4.1`), asi que cambiar de modelo es
`/models` en el TUI o `--model` en la CLI:

```bash
opencode                      # TUI: /models para cambiar de modelo en caliente

# o sin abrir el TUI, modelo local (on-prem, soberania de datos):
opencode run --model local/gpt-oss-20b \
  "Escribe un script en bash que resuma los goles del Atletico de esta temporada leyendo as.com"

# el mismo prompt contra el modelo cloud (solo desarrolladores):
opencode run --model cloud/gpt-4.1 \
  "Refactoriza ese script con manejo de errores y tests"
```

> "Mismo agente, dos modelos, una sola credencial de plataforma. El desarrollador elige potencia; el CIO
> sigue teniendo el limite de tokens."

**La red del sandbox tambien es politica.** En vez de `curl`, que lo pruebe el propio agente. Pideselo en
lenguaje natural, dentro del TUI de OpenCode (`opencode`), donde puedes aprobar los permisos de herramientas:

```
Conectate al periodico as.com y dime las ultimas noticias relacionadas con el Atletico de Madrid
```

```
Ahora mira en marca.com
```

Salida real de este cluster:

```
%  WebFetch https://as.com
   Access successful, content retrieved.

✗  WebFetch https://marca.com failed
   Error: StatusCode: non 2xx status code (403 GET https://marca.com)
   403 Forbidden - access was blocked.
```

El agente entra en AS y, al intentar Marca, recibe un **403 del propio sandbox**, no del periodico.

> "Estamos en el estadio del Atletico. Aqui no se lee Marca."
>
> "En serio: es deny-by-default. La allowlist tiene el gateway de MaaS, npm, PyPI, GitHub en solo-lectura
> y as.com. Todo lo demas se bloquea en el sandbox, no en el destino. Y el agente no puede saltarselo
> porque la politica se aplica por binario y por metodo HTTP, fuera del proceso del agente."

**Dos avisos de ensayo** (comprobados en este cluster):

- Usa el **TUI**, no `opencode run`. En modo no interactivo las peticiones de permiso se auto-rechazan
  (`permission requested: external_directory (/*); auto-rejecting`) y el agente se queda a medias. Y sin
  el contexto de la conversacion, "Ahora mira en marca.com" lo interpreta como buscar un fichero local,
  con lo que nunca sale a la red y te pierdes el 403.
- El titular lo lee, pero gpt-oss-20b se atraganta con el HTML gigante de la portada de AS y a veces
  concluye que no encuentra noticias del Atletico. Lo que hay que ensenar es **el acceso**, no el resumen:
  si quieres el titular fino, pregunta por una URL de seccion concreta o cambia a `cloud/gpt-4.1`.

### Cierre (30 seg)

> "Dos modelos, dos equipos, control total: soberania con el modelo local, potencia cloud bajo demanda,
> rate limiting para el coste y un sandbox deny-by-default para el agente. Todo declarativo, todo en
> OpenShift AI, y todo gestionable desde la consola."

---

## Playground por equipo

Cada equipo tiene su **proyecto** y es admin de el (`manifests/03-projects/team-projects.yaml`):

| Equipo | Proyecto | Admin |
|---|---|---|
| Desarrolladores | `desarrolladores-1-proyecto` | `desarrollador-1` + grupo `scm-desarrolladores` |
| Ventas | `ventas-1-proyecto` | `vendedor-1` + grupo `scm-ventas` |

El **Playground** de Gen AI studio es por proyecto y necesita un LlamaStack (`OGXServer`) desplegado en el:
sin el, `Add to playground` devuelve 500 y la pagina dice "You must create a project to begin".

Camino en la UI:

1. `Gen AI studio` → `AI asset endpoints` → selecciona el proyecto del equipo → `Add to playground`
   en cada modelo que quieras exponer.
2. `Gen AI studio` → `Playground` → selecciona el proyecto.
3. En `Settings` del playground: elige **Model** y **Subscription** (la suscripcion del equipo).

![Playground del equipo de Desarrolladores](docs/images/14-playground-cloud-model.png)

El playground pasa por el gateway de MaaS con la suscripcion del equipo, asi que la matriz de acceso se ve
sin tocar nada mas: en el proyecto de Ventas el modelo cloud no esta disponible; en el de Desarrolladores si.
Como plantilla declarativa de `OGXServer` hay `manifests/03-projects/playground-ogxserver.yaml.template`.

## Archivos del repositorio

```
manifests/
  01-models/                          Los dos modelos, uno por directorio
    gpt-oss-20b/                        Local, en GPU (kustomize, de rhoai-maas-guide)
      llm/                                LLMInferenceService (vLLM CUDA)
      maas/                               MaaSModelRef, auth policy y suscripciones base
    cloud-openai/                       Cloud, OpenAI (aplicar en orden)
      00-namespace.yaml                   Namespace con labels de gateway
      01-secret-openai.yaml               Secret de la clave OpenAI (REPLACE_ME)
      02-external-provider.yaml           ExternalProvider (openai -> api.openai.com)
      03-external-model.yaml              ExternalModel: gpt-5.5
      04-maas-model-ref.yaml              MaaSModelRef que lo publica en el gateway
      06-external-model-gpt41.yaml        ExternalModel + MaaSModelRef: gpt-4.1 (OpenCode)
  02-governance/                      Quien accede a que, y con que limites
    auth-policies.yaml                  Cloud: grupo desarrolladores + admin
    subscriptions.yaml                  Limites por equipo (priority 30)
  03-projects/                        Espacio de trabajo de cada equipo
    team-projects.yaml                  desarrolladores-1-proyecto y ventas-1-proyecto
    playground-ogxserver.yaml.template   Plantilla de OGXServer para el playground
  04-sandbox/                         El agente y su jaula
    openshell-values.yaml               Helm values del gateway de OpenShell
    openshell-route.yaml                Route passthrough TLS (referencia)
    opencode-config.json                OpenCode: providers local/ y cloud/
    policy-scm.yaml.template            Politica del sandbox (as.com si, marca.com no)

scripts/
  setup-demo.sh                     Usuarios, grupos, modelo cloud, gobernanza, proyectos
  check-demo.sh                     Comprobacion previa (los fallos tipicos)
  run-demo.sh                       Matriz de acceso y rate limits (429)
  install-openshell.sh              Gateway de OpenShell
  setup-sandbox.sh                  Sandbox + OpenCode + politica de red
  cleanup-demo.sh                   Borrar todo
  common.sh                         Funciones compartidas

docs/images/                        Capturas de cada pantalla del guion
```

Los directorios de `manifests/` van numerados en el orden en que se aplican, y ese orden es el mismo
que el de los actos de la demo: primero los modelos, luego la gobernanza, luego los proyectos de cada
equipo y por ultimo el sandbox del agente.

---

## Troubleshooting

Los cuatro fallos reales que hemos visto en este cluster, con su sintoma exacto:

| Sintoma | Causa | Arreglo |
|---|---|---|
| La UI de MaaS muestra **0 modelos** al presentador; `/maas-api/v1/models` devuelve `{"data":[]}` | La visibilidad va por suscripcion + politica de autorizacion. Ser `cluster-admin` no da acceso | Añade el usuario a `spec.owner.users` de la suscripcion y a `spec.subjects.users` de la `MaaSAuthPolicy` (son listas de **strings**, no de objetos) |
| En **External models** no aparece el modelo cloud | El selector **Project** esta en `ai-tenants` | Cambia el proyecto a `external-models` |
| El modelo cloud da `404` y en los logs del gateway se ve `via_upstream` con el path completo | El `ExternalModel` se llamaba distinto que el modelo del proveedor. La HTTPRoute generada casa por header `X-Gateway-Model-Name: <targetModel>` mientras el ext-proc resuelve el alias, y nada reescribe el prefijo `/external-models/<name>` | El `ExternalModel` (y `modelName`) tiene que llamarse **exactamente igual** que `targetModel`, como en rhoai-maas-guide, y los clientes usan `POST /v1/chat/completions` con el modelo en el body |
| `400 Unsupported parameter: 'max_tokens' is not supported with this model` | `gpt-5.5` solo acepta `max_completion_tokens` | Cambia el parametro; `gpt-4.1` acepta los dos |
| OpenCode con un modelo cloud `gpt-5.*` falla con `400 Unknown parameter: 'reasoningSummary'` | OpenCode inyecta parametros de razonamiento para todo id de la familia gpt-5 (metadatos de models.dev). No se desactiva con `reasoning: false`, `options: {}` ni `npm: @ai-sdk/openai-compatible` | Usa `gpt-4.1` para el agente (ya configurado en `04-sandbox/opencode-config.json`) |
| La **primera** peticion al modelo cloud devuelve `503 upstream connect error` y las siguientes `200` | Envoy tiene que levantar la conexion TLS con el proveedor externo | Calienta el modelo con una peticion antes de salir al escenario; `check-demo.sh` reintenta una vez |
| Dentro del sandbox, OpenCode no ve ningun modelo; `curl` al gateway devuelve `403` y la lista sale vacia | **API key de MaaS caducada** (las de `expiresIn: 24h` mueren al dia siguiente) | Crea otra en la UI con 30 dias y re-ejecuta `setup-sandbox.sh` |
| OpenCode falla con `Error: Forbidden: policy_denied` pero `curl` al mismo endpoint funciona | La politica del sandbox autoriza binarios por ruta y OpenCode vive en `/sandbox/.npm-global/...` | Ya corregido en `04-sandbox/policy-scm.yaml.template`. Recarga en caliente: `openshell policy set --policy <file> --wait <sandbox>` |
| El proyecto muestra el banner *"Kueue is disabled in this cluster"* | `OdhDashboardConfig` tiene `disableKueue: true` y el namespace lleva `kueue.openshift.io/managed` | `oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge -p '{"spec":{"dashboardConfig":{"disableKueue":false}}}'` y **recarga sin cache** (con F5 normal el banner sigue) |
| Desde el workbench, `openshell gateway add http://openshell:8080` dice *Gateway is not reachable* y luego *dns error* | El gateway vive en el namespace `sandbox-scm`, no en el del workbench, y sirve **TLS con mTLS** | Usa el FQDN `https://openshell.sandbox-scm.svc.cluster.local:8080` y copia el material mTLS del cliente, o conecta desde el portatil del presentador |

## Limpiar

```bash
./scripts/cleanup-demo.sh
```

Elimina usuarios, grupos, modelo cloud y gobernanza. No toca gpt-oss-20b ni la instalacion de MaaS.
