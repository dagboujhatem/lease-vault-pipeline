# Objectif

Dans un Pod Kubernetes, tu veux :

Récupérer des secrets depuis Vault

Utiliser ces secrets pendant la vie du Pod

Détruire proprement les leases à l’arrêt du Pod

👉 La bonne solution repose sur :

initContainer → récupération des secrets

preStop hook → révocation des leases

token Vault avec lease (K8s auth, AppRole…)

## Solution 1 : Init Container & preStop Hook (Manuel)
 
👉 Cette approche repose sur des scripts personnalisés pour récupérer et révoquer les secrets.
 
### ✅ Avantages :
- **Faible consommation de ressources** : Pas de container permanent supplémentaire (sidecar).
- **Contrôle total** : Tu maîtrises exactement comment et quand les secrets sont récupérés et révoqués.
- **Pas de dépendance externe** : Pas besoin d'installer l'Agent Vault ou le Driver CSI dans le cluster.
 
### ❌ Inconvénients :
- **Maintenance élevée** : Nécessite l'écriture et le maintien de scripts Bash/Python dans le YAML.
- **Pas de renouvellement automatique** : Si le secret expire pendant la vie du Pod, l'application doit gérer le rafraîchissement elle-même.
- **Outils requis dans l'image applicative** : Pour que le `preStop` hook fonctionne, l'image de ton container principal **doit contenir `curl` ou le binaire `vault`**. Par exemple, une image Spring Boot standard ne contient aucun de ces outils, ce qui t'oblige à les rajouter, alourdissant l'image et augmentant la surface d'attaque.
- **Complexité du YAML** : Le manifeste devient verbeux avec les scripts intégrés.
 
### Architecture : 

```shell 
Pod lifecycle
│
├── initContainer
│     └── login Vault
│     └── read secrets
│     └── stocker secrets (volume)
│     └── sauvegarder lease_id
│
├── container principal
│     └── utilise les secrets
│
└── preStop hook
      └── revoke lease(s)
```

### 1. initContainer – récupérer les secrets


Rôle

- s’authentifier à Vault
- récupérer les secrets
- conserver les lease_id
- écrire les secrets dans un volume partagé

```yaml 
initContainers:
- name: vault-init
  image: curlimages/curl:8.5.0
  env:
  - name: VAULT_ADDR
    value: "https://vault:8200"
  - name: VAULT_TOKEN
    valueFrom:
      secretKeyRef:
        name: vault-token
        key: token
  volumeMounts:
  - name: vault-data
    mountPath: /vault
  command:
  - sh
  - -c
  - |
    set -e

    # Lire un secret dynamique
    RESPONSE=$(curl -s \
      -H "X-Vault-Token: $VAULT_TOKEN" \
      $VAULT_ADDR/v1/database/creds/app-role)

    echo "$RESPONSE" | jq -r '.data.username' > /vault/db_user
    echo "$RESPONSE" | jq -r '.data.password' > /vault/db_pass

    # Sauvegarder le lease_id
    echo "$RESPONSE" | jq -r '.lease_id' > /vault/lease_id
```

### 2. Container principal – utiliser les secrets

```yaml 
containers:
- name: app
  image: my-app:latest
  volumeMounts:
  - name: vault-data
    mountPath: /vault
  env:
  - name: DB_USER
    valueFrom:
      secretKeyRef:
        name: dummy # ou lu depuis fichier au démarrage
```


### 3. preStop hook – détruire les leases

Rôle

- lire les lease_id
- appeler sys/leases/revoke
- cleanup propre

```yaml 
lifecycle:
  preStop:
    exec:
      command:
      - sh
      - -c
      - |
        set -e

        if [ -f /vault/lease_id ]; then
          LEASE_ID=$(cat /vault/lease_id)

          echo "Revoking lease $LEASE_ID"

          curl -s \
            -H "X-Vault-Token: $VAULT_TOKEN" \
            -X POST \
            $VAULT_ADDR/v1/sys/leases/revoke/$LEASE_ID
        fi

```

Résultat : 
Aucun secret n’est relu ici
📌 Seulement du revoke

### 4. terminationGracePeriodSeconds (OBLIGATOIRE)

```yaml 
terminationGracePeriodSeconds: 30
```

Pourquoi ?

- Kubernetes donne du temps au preStop
- Vault doit répondre
- éviter les leases orphelins


## Solution 2 : Vault Agent Sidecar (Injection)
 
👉 C’est la méthode recommandée pour la plupart des usages. Elle utilise des **annotations** pour injecter un agent Vault qui gère tout automatiquement.
 
### ✅ Avantages :
- **Automatisation complète** : Gère le login, le renouvellement (renew) et la révocation (revoke) sans code.
- **Simplicité pour l'application** : L'application lit simplement un fichier local (volume partagé).
- **Formatage flexible** : Utilise des templates (Consul Template) pour générer des fichiers de config personnalisés.
- **Sécurité** : L'application n'a jamais accès au token Vault, seulement au résultat.
 
### ❌ Inconvénients :
- **Consommation de ressources** : Ajoute un container supplémentaire (sidecar) par Pod (Plus de consommation des ressources (CPU/RAM)).
- **Dépendance cluster** : Nécessite l'installation du **Vault Agent Injector** par l'administrateur.
- **Délai au démarrage** : Le sidecar doit être prêt avant que l'application ne démarre.
- **Risque de Leases Orphelins (Node KO)** : Si le nœud Kubernetes subit une panne brutale (Hard Crash/KO), le sidecar n'aura pas le temps de révoquer ses baux, créant ainsi des "orphan leases" dans Vault jusqu'à leur expiration naturelle (TTL).

### Exemple de configuration (Deployment) :
```yaml
spec:
  template:
    metadata:
      annotations:
        # 1. Activer l'injection
        vault.hashicorp.com/agent-inject: "true"
        # 2. Définir le rôle Vault
        vault.hashicorp.com/role: "my-app-role"
        # 3. Définir le secret à injecter et son template
        vault.hashicorp.com/agent-inject-secret-database-config: "database/creds/my-app"
        vault.hashicorp.com/agent-inject-template-database-config: |
          {{- with secret "database/creds/my-app" -}}
          spring.datasource.username={{ .Data.username }}
          spring.datasource.password={{ .Data.password }}
          {{- end -}}
    spec:
      serviceAccountName: my-app-sa
```
Le secret sera disponible dans `/vault/secrets/database-config`.

## Solution 3 : Secrets Store CSI Driver
 
👉 Cette méthode monte les secrets directement comme un **volume natif** Kubernetes via le standard CSI.
 
### ✅ Avantages :
- **Performance** : Pas de sidecar par Pod, utilise un démon sur chaque nœud (plus efficace à grande échelle).
- **Standard Kubernetes** : Utilise les mécanismes natifs de volumes.
- **Sync K8s Secret** : Peut créer un Secret K8s réel à partir de Vault.
- **Sécurité accrue** : Les secrets sont montés en mémoire (tmpfs) et non écrits sur le disque persistant.
- **Résilience aux pannes de nœuds (Node KO)** : Contrairement au sidecar, le Driver CSI (DaemonSet) peut mieux gérer le cycle de vie des volumes et des secrets associés, réduisant le risque de baux orphelins en cas de crash du nœud.
 
### ❌ Inconvénients :
- **Configuration plus lourde** : Nécessite de créer des objets `SecretProviderClass` séparés.
- **Formatage limité** : Moins flexible que les templates de l'Agent pour transformer les données.
- **Complexité d'installation** : Nécessite d'installer plusieurs composants (CSI Driver + Vault Provider).

### Exemple de SecretProviderClass :
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-db-creds
spec:
  provider: vault
  parameters:
    roleName: "my-app-role"
    objects: |
      - objectName: "db_user"
        secretPath: "database/creds/my-app"
        secretKey: "username"
      - objectName: "db_pass"
        secretPath: "database/creds/my-app"
        secretKey: "password"
```

### Utilisation dans le Pod :
```yaml
spec:
  volumes:
    - name: secrets-store-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "vault-db-creds"
```

## Comparatif des approches

| Critère | Solution 1 (Manuel) | Solution 2 (Sidecar) | Solution 3 (CSI Driver) |
| :--- | :--- | :--- | :--- |
| **Complexité** | Élevée (scripts YAML) | Moyenne (annotations) | Moyenne (CRD) |
| **Ressources** | Faible (Init temporaire) | Moyenne (Sidecar permanent) | Faible (Driver partagé) |
| **Auto-Renew** | Non (sauf via app) | ✅ Oui | ✅ Oui |
| **Auto-Revoke** | ✅ Oui (via preStop) | ✅ Oui | ✅ Oui |
| **Formatage** | Script `jq`/`bash` | Templates Consul (Agent) | Fichiers bruts |
| **Usage recommandé** | Debug / Environnement restreint | **Standard Entreprise** | Intégration OS / Native K8s |

## Rappel : Lifecycle du Pod

Ce que fait Kubernetes lors d’un arrêt de Pod

```shell 
kubectl delete pod
│
├── preStop hook (si défini)   ← ICI
│
├── SIGTERM envoyé au container
│
├── attente (terminationGracePeriodSeconds)
│
└── SIGKILL (forcé)
```

#### Sans preStop

- token Vault toujours valide
- leases dynamiques toujours actifs
- orphans
- fuite de credentials (DB, cloud, etc.)

#### Avec preStop

- révocation explicite des leases
- cleanup immédiat
- sécurité maîtrisée

Cas d’usage typiques du preStop

| Cas                   | Pourquoi preStop  |
| --------------------- | ----------------- |
| Vault sans agent      | Révoquer leases   |
| DB connection pool    | Fermer proprement |
| Message broker        | Ack / drain       |
| Locks distribués      | Release           |
| Side effects externes | Cleanup           |


Aller plus loin 

| Mécanisme     | Rôle           | Moment      |
| ------------- | -------------- | ----------- |
| initContainer | Préparer       | Avant start |
| postStart     | Init légère    | Après start |
| readiness     | Traffic        | Continu     |
| liveness      | Crash          | Continu     |
| startup       | Démarrage lent | Boot        |
| preStop       | Cleanup        | Avant stop  |
| SIGTERM       | Shutdown       | Stop        |
