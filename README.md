# Summit Connect Madrid - MaaS: Gobernanza de IA en la Empresa

Model as a Service: facilitando el acceso gobernado a modelos de IA - local y cloud - con Red Hat OpenShift AI.

Demo de 20 minutos en el estadio del Atletico de Madrid.

## La historia

Una empresa tiene dos equipos que necesitan acceso a modelos de IA: **Desarrolladores** y **Ventas**. El CIO tiene tres prioridades:

1. **Soberania de datos**: los datos sensibles no salen del data center. Hay un modelo local (gpt-oss-20b) corriendo en GPU propia.
2. **Potencia cuando se necesita**: para tareas complejas, hay un modelo cloud (Claude Opus 5) disponible bajo demanda.
3. **Control de costes**: el modelo cloud es caro. Solo los desarrolladores pueden usarlo, y con limites estrictos.

La plataforma tiene que hacer cumplir todo esto sin que nadie tenga que "portarse bien" manualmente.

## Arquitectura

```
                    ┌─────────────────────────────────────────┐
                    │            MaaS Gateway                 │
                    │   maas.apps.ocp.xxx.opentlc.com         │
                    └──────────┬───────────────┬──────────────┘
                               │               │
                    ┌──────────▼──────┐  ┌─────▼──────────────┐
                    │  gpt-oss-20b    │  │  opus5-cloud       │
                    │  (GPU local)    │  │  (Cloud - Opus 5)  │
                    │  namespace: llm │  │  ns: external-     │
                    │  vLLM en L40S   │  │      models        │
                    └─────────────────┘  └────────────────────┘
```

## Matriz de acceso

| Equipo | gpt-oss-20b (local) | opus5-cloud (cloud) |
|--------|:-------------------:|:-------------------:|
| **Desarrolladores** | 1000 tok/min | 100 tok/min |
| **Ventas** | 500 tok/min | Sin acceso |

El modelo cloud tiene un limite 10x mas bajo que el local. El CIO controla el gasto sin quitar funcionalidad.

## Preparacion (antes de la demo)

### 1. GPU y plataforma MaaS (~45 min)

```bash
# Login al cluster
oc login https://api.ocp.trdq4.sandbox1354.opentlc.com:6443 -u admin -p <password>

# GPU MachineSet (g6e.xlarge para L40S)
cd ocp-gpu-setup && ./machine-set/gpu-machineset.sh

# MaaS + gpt-oss-20b + observabilidad
cd rhoai-maas-guide
./scripts/setup-maas.sh --model gpt-oss-20b --with-observability
```

### 2. Clave ABSK para el modelo cloud (~5 min)

```bash
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
cd z-collateral
./provision-bedrock-anthropic.sh --models anthropic.claude-opus-5 --region us-east-1
```

Guardar la clave ABSK que aparece en pantalla (solo se muestra una vez).

### 3. Desplegar la demo (~5 min)

```bash
cd summit-connect-madrid-maas
DEMO_PASSWORD='redhat123' ABSK_KEY='ABSK...' ./scripts/setup-demo.sh
```

Esto crea los usuarios, grupos, modelo externo, politicas de acceso y suscripciones.

### 4. OpenShell + OpenCode (~10 min)

```bash
# Instalar el gateway OpenShell
./scripts/install-openshell.sh

# Primero, generar un API key de MaaS para desarrollador-1
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
TOKEN=$(oc login -u desarrollador-1 -p redhat123 --server=$(oc whoami --show-server) -t 2>/dev/null | grep -oP 'token=\K.*' || oc whoami -t)
MAAS_KEY=$(curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X POST -d '{"name":"sandbox-key","expiresIn":"24h"}' \
  "https://maas.${CLUSTER_DOMAIN}/maas-api/v1/api-keys" | jq -r '.key')

# Login como admin de nuevo
oc login -u admin -p <password> --server=$(oc whoami --show-server)

# Crear el sandbox con OpenCode
MAAS_API_KEY="$MAAS_KEY" ./scripts/setup-sandbox.sh
```

### 5. Verificar

```bash
./scripts/run-demo.sh
```

Deberia mostrar:
- desarrollador-1: ve 2 modelos, gpt-oss-20b OK, opus5-cloud rate-limited
- vendedor-1: ve 1 modelo, gpt-oss-20b OK, opus5-cloud 403

---

## Guion de la demo (20 minutos)

### Acto 1 - El problema del CIO (3 min)

> "Imaginad que sois el CIO de una empresa. Teneis dos equipos - desarrolladores y ventas - y dos modelos de IA: uno local en vuestras GPUs y otro en la nube. El local es seguro pero limitado. El de la nube es potente pero caro. Como dais acceso a cada equipo con las garantias que necesitais?"

**Mostrar**: RHOAI Dashboard con los dos modelos registrados.

### Acto 2 - Dos modelos, dos mundos (5 min)

> "Aqui tenemos gpt-oss-20b corriendo en una GPU L40S dentro del cluster. Los datos nunca salen. Y aqui tenemos Opus 5, un modelo cloud de alta capacidad, registrado como modelo externo. MaaS los trata igual para gobernanza."

**Mostrar**:
- `oc get llminferenceservice -n llm` - modelo local corriendo
- `oc get externalmodel -n external-models` - modelo cloud registrado
- `oc get maasmodelref -A` - ambos en estado Ready

**Hacer**: una peticion de inferencia rapida a cada modelo desde curl para demostrar que ambos funcionan.

```bash
# Usar el admin token
TOKEN=$(oc whoami -t)
H="https://maas.${CLUSTER_DOMAIN}"

# Local
curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X POST -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Hola, que modelo eres?"}],"max_tokens":50}' \
  "${H}/llm/gpt-oss-20b/v1/chat/completions" | jq .choices[0].message.content

# Cloud
curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X POST -d '{"model":"opus5-cloud","messages":[{"role":"user","content":"Hola, que modelo eres?"}],"max_tokens":50}' \
  "${H}/external-models/opus5-cloud/v1/chat/completions" | jq .choices[0].message.content
```

### Acto 3 - Gobernanza como politica (7 min)

> "Ahora viene lo interesante. No confiamos en que la gente se porte bien - la plataforma lo garantiza."

**Mostrar** los YAMLs de gobernanza:
```bash
# Quien puede acceder a que
oc get maasauthpolicy -n models-as-a-service
# Cuanto puede consumir cada equipo
oc get maassubscription -n models-as-a-service
```

**Demo interactiva** (usar run-demo.sh o hacer manualmente):

```bash
# Como vendedor-1: solo ve 1 modelo
oc login -u vendedor-1 -p redhat123
TOKEN=$(oc whoami -t)
curl -sk -H "Authorization: Bearer $TOKEN" "${H}/maas-api/v1/models" | jq '.data[].id'
# Solo aparece gpt-oss-20b

# Intentar el modelo cloud -> 403
# (generar API key y hacer la peticion)

# Como desarrollador-1: ve 2 modelos
oc login -u desarrollador-1 -p redhat123
TOKEN=$(oc whoami -t)
curl -sk -H "Authorization: Bearer $TOKEN" "${H}/maas-api/v1/models" | jq '.data[].id'
# Aparecen gpt-oss-20b y opus5-cloud
```

> "Ventas ve un modelo. Desarrolladores ven dos. La misma plataforma, diferentes permisos. Y si desarrolladores abusa del modelo cloud..."

**Mostrar rate limiting**: enviar varias peticiones rapidas al modelo cloud y ver que llega el 429.

### Acto 4 - El sandbox del desarrollador (5 min)

> "Y ahora, el entorno del desarrollador. Un sandbox aislado con OpenCode, conectado a los modelos via MaaS."

**Mostrar**: abrir OpenShell en el navegador, ejecutar `opencode`.

**Demo**:
1. Usar OpenCode con el modelo local (gpt-oss-20b) - pedir que genere un script
2. Cambiar al modelo cloud (opus5-cloud) - pedir algo mas complejo
3. Probar el acceso a internet:

```bash
# Dentro del sandbox
curl -I https://as.com
# 200 OK - noticias del Atletico

curl -I https://marca.com
# Connection refused - bloqueado!
```

> "Estamos en el estadio del Atletico. Aqui no se lee Marca."

**(aplausos)**

> "En serio - la politica de red controla que sitios puede acceder el sandbox. Solo lo que esta en la allowlist pasa. Todo lo demas esta bloqueado por defecto."

### Cierre (30 seg)

> "Recapitulando: dos modelos, dos equipos, control total. Soberania de datos con el modelo local. Potencia cloud cuando se necesita. Rate limiting para controlar costes. Todo declarativo, todo como codigo, todo en OpenShift AI."

---

## Archivos del repositorio

```
manifests/
  namespace-external-models.yaml    Namespace con labels de gateway
  external-provider-opus5.yaml      ExternalProvider (Anthropic + Mantle)
  external-model-opus5.yaml         ExternalModel: opus5-cloud
  httproute-opus5-compat.yaml       Compat HTTPRoute (ext-proc path rewrite fix)
  secret-opus5.yaml                 Secret template (REPLACE_ME)
  maas-model-opus5.yaml             MaaSModelRef para opus5-cloud
  auth-policies.yaml                Control de acceso: cloud solo desarrolladores
  subscriptions.yaml                Limites por equipo (priority 30)
  opencode-config.json              Configuracion OpenCode (2 modelos)
  policy-scm.yaml.template          Politica de red: as.com si, marca.com no
  openshell-values.yaml             Helm values para OpenShell
  openshell-route.yaml              Route passthrough TLS (referencia)

scripts/
  setup-demo.sh                     Desplegar todo: usuarios, modelos, gobernanza
  run-demo.sh                       Ejecutar la demo interactiva
  cleanup-demo.sh                   Eliminar todo
  install-openshell.sh              Instalar OpenShell gateway
  setup-sandbox.sh                  Crear sandbox con OpenCode
  common.sh                         Funciones compartidas
```

## Limpiar

```bash
./scripts/cleanup-demo.sh
```

Esto elimina los usuarios, grupos, modelo externo y gobernanza. No toca gpt-oss-20b ni la instalacion de MaaS.
