# Objectif

Dans un Pod Kubernetes, tu veux :

Récupérer des secrets depuis Vault

Utiliser ces secrets pendant la vie du Pod

Détruire proprement les leases à l’arrêt du Pod

👉 La bonne solution repose sur :

initContainer → récupération des secrets

preStop hook → révocation des leases

token Vault avec lease (K8s auth, AppRole…)

## Architecture : 

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

## 1. initContainer – récupérer les secrets


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

## 2.  Container principal – utiliser les secrets

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


## 3. preStop hook – détruire les leases

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

## 4. terminationGracePeriodSeconds (OBLIGATOIRE)

```yaml 
terminationGracePeriodSeconds: 30
```

Pourquoi ?

- Kubernetes donne du temps au preStop
- Vault doit répondre
- éviter les leases orphelins


## 5. Alternative RECOMMANDÉE (encore mieux)

👉 Vault Agent sidecar

Avantages :

- renew automatique
- revoke automatique
- aucun script
- gestion native des leases

## 6. Rappel 

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
