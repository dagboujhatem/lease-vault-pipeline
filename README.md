# Pipeline GitLab CI pour la gestion des Leases Vault

![GitLab CI](https://img.shields.io/badge/GitLab-CI%2FCD-orange?logo=gitlab)
![Vault](https://img.shields.io/badge/Vault-HashiCorp-000000?logo=vault)
![Bash](https://img.shields.io/badge/Bash-Script-4EAA25?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)

Cette pipeline permet de lister et de détruire les leases Vault dans un projet GitLab CI/CD.

## ⚠️ Avertissement Important - Architecture et Criticité

### Architecture des Environnements Vault

Cette infrastructure utilise **deux environnements Vault distincts** :

1. **Vault HPROD** (`hprod`)
   - Héberge les environnements de développement et de qualification :
     - `dev` (développement)
     - `int` (intégration)
     - `qua` (qualification)

2. **Vault PROD** (`prod`)
   - Héberge les environnements de production :
     - `pprod` (pré-production)
     - `prod` (production)

### Mapping Namespace → CodeAp

Chaque **namespace** correspond à un **codeAp unique** (exemple : `APXXXXX`). Ce codeAp identifie de manière unique l'application ou le service dans l'infrastructure.

**Exemple de mapping :**
```
Namespace: my-app-dev    → CodeAp: AP12345 (dans hprod)
Namespace: my-app-int    → CodeAp: AP12345 (dans hprod)
Namespace: my-app-prod   → CodeAp: AP67890 (dans prod)
```

### ⚠️ Criticité de l'Opération

**ATTENTION : La destruction de leases est une opération CRITIQUE qui peut avoir des impacts majeurs sur l'infrastructure !**

#### Conséquences Potentielles

La destruction de leases peut entraîner :

1. **Arrêt de tous les Pods Kubernetes** utilisant des secrets Vault
   - Les pods qui dépendent de ces leases perdront immédiatement l'accès à leurs secrets
   - Les pods ne pourront plus s'authentifier auprès des services externes (AWS, bases de données, APIs, etc.)
   - Résultat : **Arrêt complet de l'application ou du service**

2. **Interruption des Pipelines CI/CD**
   - Les pipelines IAC (Infrastructure as Code) peuvent échouer
   - Les pipelines CD (Continuous Deployment) ne pourront plus déployer
   - Les jobs en cours d'exécution échoueront
   - Résultat : **Blocage des déploiements et de la livraison**

3. **Perte d'accès aux Ressources Cloud**
   - Credentials AWS/Azure/GCP invalides
   - Perte d'accès aux buckets S3, bases de données, services managés
   - Résultat : **Services inaccessibles, données non disponibles**

#### Procédure Recommandée AVANT la Destruction

**🔴 OBLIGATOIRE : Suivre cette procédure avant d'entamer la destruction de leases pour un namespace donné :**

1. **Identifier le namespace et le codeAp concerné**
   ```bash
   # Exemple : Vérifier quel codeAp correspond au namespace
   namespace="my-app-prod"
   codeAp="AP67890"
   ```

2. **Arrêter tous les Pods utilisant ce namespace**
   ```bash
   # Lister tous les pods du namespace
   kubectl get pods -n <namespace> -o wide
   
   # Arrêter/drainer les pods (selon votre stratégie de déploiement)
   kubectl scale deployment --replicas=0 -n <namespace>
   # OU
   kubectl delete pods -n <namespace> --all
   ```

3. **Arrêter toutes les Pipelines actives utilisant ce namespace**
   - Vérifier dans GitLab CI/CD les pipelines en cours
   - Annuler/arrêter toutes les pipelines liées au codeAp/namespace
   - Attendre que toutes les pipelines soient terminées

4. **Vérifier l'état actuel des leases**
   ```bash
   # Utiliser cette pipeline pour LISTER les leases AVANT de détruire
   LEASE_LIST_PATHS="<path-du-namespace>"
   # Exécuter seulement le stage list_leases
   ```

5. **Planifier une fenêtre de maintenance**
   - Informer les équipes concernées
   - Planifier un créneau de maintenance
   - Avoir un plan de rollback

6. **Vérifier les dépendances**
   - Identifier toutes les applications qui dépendent de ce namespace
   - Vérifier l'impact sur les services en aval

#### Vérification Pré-Destruction

**Avant de détruire des leases, utilisez cette pipeline pour :**

1. ✅ **Lister tous les leases** du namespace concerné
2. ✅ **Identifier les leases orphelins uniquement** (utiliser `DESTROY_ORPHANS_ONLY=true`)
3. ✅ **Vérifier le fichier JSON** généré pour valider les leases à détruire
4. ✅ **S'assurer qu'aucun pod ou pipeline actif n'utilise ces leases**

#### Recommandation

**⚠️ RECOMMANDATION FORTE :**

- **Ne détruire QUE les leases orphelins** (`DESTROY_ORPHANS_ONLY=true`)
- **Ne JAMAIS détruire tous les leases** si des pods/pipelines actifs existent
- **Toujours commencer par lister** avant de détruire
- **Utiliser la destruction manuelle** (`when: manual`) pour avoir un contrôle total
- **Tester sur un environnement non-critique** (dev/int) avant d'appliquer en production

#### Exemple de Procédure Sécurisée

```bash
# 1. Lister les leases du namespace (sans détruire)
export VAULT_ADDR="https://vault-prod.example.com"
export LEASE_LIST_PATHS="aws/creds/my-app-prod,database/creds/my-app-prod"
# Exécuter: stage list_leases uniquement

# 2. Vérifier le fichier JSON généré
cat leases.json | jq '.[] | select(.orphan == true) | {full_path, orphan, ttl}'

# 3. Arrêter les pods et pipelines du namespace
kubectl scale deployment --replicas=0 -n my-app-prod
# Annuler les pipelines GitLab actives

# 4. Attendre confirmation que tout est arrêté
# ... vérification manuelle ...

# 5. SEULEMENT APRÈS, détruire les leases orphelins
export DESTROY_ORPHANS_ONLY="true"
# Exécuter manuellement: stage destroy_leases
```

## Prérequis

Avant d'utiliser cette pipeline, assurez-vous d'avoir :

- **Un projet GitLab** avec GitLab CI/CD activé
- **Accès à un serveur Vault** fonctionnel et accessible depuis les runners GitLab
- **Un token Vault** avec les permissions nécessaires (voir section [Permissions Vault requises](#permissions-vault-requises))
  - Le token doit avoir les capacités `list`, `read` sur `sys/leases/subkeys/*` et `sys/leases/lookup/*`
  - Pour la destruction, le token doit avoir la capacité `update` sur `sys/leases/revoke/*`
- **Connaissance de base** de Vault et du concept de leases
- **Les outils nécessaires** (curl, jq, bash) sont automatiquement installés dans la pipeline via l'image Docker `vault:latest`

### Vérification des Capacités Vault

Avant d'utiliser cette pipeline, il est **essentiel** de vérifier que votre token Vault dispose des permissions nécessaires. 

> **💡 Astuce :** La pipeline exécute automatiquement un script de pré-vérification (`check-capabilities.sh`) dans le stage `check_capabilities`. Vous pouvez également utiliser ce script manuellement pour vérifier vos permissions avant d'exécuter la pipeline complète.

**Vérification rapide avec le script :**
```bash
export VAULT_ADDR="http://vault.example.com:8200"
export VAULT_TOKEN="votre-token"
./scripts/check-capabilities.sh
```

Voici également plusieurs méthodes manuelles pour vérifier les capacités :

#### Méthode 1 : Via l'API Vault (curl)

Utilisez l'endpoint `/v1/sys/capabilities-self` ou `/v1/sys/capabilities` pour vérifier les capacités sur des paths spécifiques :

**Vérifier les capacités de listing (subkeys) :**
```bash
# Exporter les variables d'environnement
export VAULT_ADDR="http://vault.example.com:8200"
export VAULT_TOKEN="votre-token"

# Vérifier la capacité 'list' sur sys/leases/subkeys/
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"paths": ["sys/leases/subkeys/"]}' \
  "$VAULT_ADDR/v1/sys/capabilities" | jq '.'

# Résultat attendu : {"sys/leases/subkeys/": ["list", "read", "deny"] ou équivalent}
```

**Vérifier la capacité 'read' sur lookup :**
```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"paths": ["sys/leases/lookup/test"]}' \
  "$VAULT_ADDR/v1/sys/capabilities" | jq '.'
```

**Vérifier la capacité 'update' sur revoke :**
```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"paths": ["sys/leases/revoke/test"]}' \
  "$VAULT_ADDR/v1/sys/capabilities" | jq '.'
```

**Script complet de vérification :**
```bash
#!/bin/bash
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN}"

if [ -z "$VAULT_TOKEN" ]; then
    echo "Erreur: VAULT_TOKEN n'est pas défini"
    exit 1
fi

echo "Vérification des capacités pour le token..."
echo "=========================================="

# Paths à vérifier
paths=(
    "sys/leases/subkeys/"
    "sys/leases/lookup/test"
    "sys/leases/revoke/test"
)

for path in "${paths[@]}"; do
    echo -n "Path: $path -> "
    caps=$(curl -s \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        --request POST \
        --data "{\"paths\": [\"$path\"]}" \
        "$VAULT_ADDR/v1/sys/capabilities" | jq -r ".[\"$path\"][]" | tr '\n' ',' | sed 's/,$//')
    echo "Capacités: [$caps]"
done
```

#### Méthode 2 : Via Vault CLI

Utilisez la commande `vault token capabilities` pour vérifier les capacités :

**Vérifier les capacités d'un path spécifique :**
```bash
# Configurer Vault CLI
export VAULT_ADDR="http://vault.example.com:8200"
export VAULT_TOKEN="votre-token"

# Vérifier les capacités pour différents paths
vault token capabilities sys/leases/subkeys/
vault token capabilities sys/leases/lookup/test
vault token capabilities sys/leases/revoke/test
```

**Vérifier toutes les capacités du token actuel :**
```bash
# Afficher les informations du token (incluant les policies)
vault token lookup

# Vérifier les capacités sur plusieurs paths
vault token capabilities -format=json sys/leases/subkeys/ | jq '.'
```

**Test pratique de lecture :**
```bash
# Essayer de lister les subkeys (devrait fonctionner)
vault list sys/leases/subkeys/

# Essayer de lire un lease (devrait fonctionner)
vault read sys/leases/lookup/aws/creds/myrole/test 2>&1 | head -5
```

#### Méthode 3 : Via l'Interface Web (UI) de Vault

1. **Connectez-vous à l'interface Vault** : Accédez à `http://vault.example.com:8200/ui`
2. **Authentifiez-vous** avec votre token
3. **Naviguez vers "Access" → "Policies"** dans le menu
4. **Sélectionnez la policy** associée à votre token
5. **Vérifiez les paths** suivants dans la policy :
   ```
   path "sys/leases/subkeys/*" {
     capabilities = ["list", "read"]
   }
   
   path "sys/leases/lookup/*" {
     capabilities = ["read"]
   }
   
   path "sys/leases/revoke/*" {
     capabilities = ["update"]
   }
   ```

#### Méthode 4 : Test End-to-End

La méthode la plus fiable est de **tester directement** les opérations que la pipeline va effectuer :

**Test 1 : Lister les subkeys**
```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request LIST \
  "$VAULT_ADDR/v1/sys/leases/subkeys/" | jq '.'

# Devrait retourner une liste de clés ou un objet vide, mais PAS une erreur de permission
```

**Test 2 : Lookup d'un lease (si des leases existent)**
```bash
# D'abord, trouver un path de lease existant
LEASE_PATH=$(curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request LIST \
  "$VAULT_ADDR/v1/sys/leases/subkeys/aws/creds/" | jq -r '.data.keys[0]' | head -1)

if [ -n "$LEASE_PATH" ] && [ "$LEASE_PATH" != "null" ]; then
    curl -s \
      --header "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/sys/leases/lookup/aws/creds/$LEASE_PATH" | jq '.'
fi
```

**Test 3 : Tenter une révocation (ATTENTION : détruit réellement le lease !)**
```bash
# ⚠️ ATTENTION : Cette commande DÉTRUIT réellement un lease
# Utilisez uniquement pour tester avec un lease de test

# TEST_LEASE_ID="test-lease-id"
# curl -s \
#   --header "X-Vault-Token: $VAULT_TOKEN" \
#   --request POST \
#   "$VAULT_ADDR/v1/sys/leases/revoke/$TEST_LEASE_ID"
```

#### Résumé des Capacités Requises

| Path | Capacité | Utilisation |
|------|----------|-------------|
| `sys/leases/subkeys/*` | `list`, `read` | Lister les paths de leases |
| `sys/leases/lookup/*` | `read` | Obtenir les détails d'un lease |
| `sys/leases/revoke/*` | `update` | Détruire/révoquer un lease |

#### Dépannage

Si vous obtenez des erreurs de permission :

1. **Erreur 403 Forbidden** : Le token n'a pas les permissions nécessaires
   - Vérifiez la policy associée au token
   - Contactez votre administrateur Vault pour obtenir les permissions

2. **Erreur 404 Not Found** : Le path n'existe pas (normal si aucun lease n'existe encore)
   - Ce n'est pas nécessairement un problème de permission
   - Vérifiez que vous pouvez accéder à d'autres paths système

3. **Token expiré** : Le token a expiré
   - Régénérez un nouveau token
   - Vérifiez la durée de vie du token : `vault token lookup`

## Fonctionnalités

- **Liste des leases** : Extrait tous les leases Vault avec leurs paths et détails dans un fichier JSON
- **Filtrage par paths** : Option pour lister uniquement les leases de paths spécifiques
- **Destruction des leases** : Détruit tous les leases ou uniquement les leases orphelins
- **Artifacts JSON** : Génère un fichier JSON avec tous les détails des leases trouvés

## Concepts : Leases et Orphelins

### Qu'est-ce qu'un Lease Vault ?

Un **lease** (bail) dans Vault est un mécanisme de gestion du cycle de vie `des secrets dynamiques` et `token vault`. Lorsqu'un secret est généré par Vault (par exemple, des credentials AWS, des clés de base de données, etc.), Vault crée automatiquement un lease associé.

Le lease contient :
- **Le secret lui-même** (credentials, tokens, etc.)
- **Une durée de vie (TTL)** : Durée pendant laquelle le secret est valide
- **Un identifiant unique** : Permet de renouveler ou révoquer le secret
- **Des métadonnées** : Informations sur l'origine du lease (path, rôle, etc.)

NB: Ce qui n’a PAS de lease
- Les secrets statiques (KV)
- Les identités externes (JWT, LDAP, OIDC)
- La méthode d’auth elle-même (La méthode d’auth Vault ne porte pas de lease ; le lease est toujours sur le token qu’elle émet.)

```shell
[Auth Method] ──login──▶ [Vault Token] ──(lease / TTL)──▶ accès aux secrets

``` 

### Sources de Leases dans votre Infrastructure

Dans votre contexte, les leases sont générés par plusieurs sources :

1. **Pipeline IAC (Infrastructure as Code)**
   - Lors du déploiement d'infrastructure via Terraform, Ansible ou d'autres outils IAC
   - Les pipelines IAC peuvent créer des secrets temporaires pour authentifier les ressources
   - Exemple : Credentials pour créer des ressources AWS, tokens pour accéder à des API

2. **Pipeline CD Managé (Continuous Deployment)**
   - Lors du déploiement d'applications dans différents environnements
   - Génération de secrets pour les applications (clés API, connexions DB, etc.)
   - Exemple : Secrets Kubernetes injectés dans les pods via Vault injector

3. **Pods Kubernetes**
   - Les pods utilisant Vault injector ou l'API Vault directement
   - Chaque pod peut obtenir des secrets dynamiques avec leurs propres leases
   - Exemple : Un pod qui récupère des credentials AWS pour accéder à S3

### Qu'est-ce qu'un Lease Orphelin ?

Un **lease orphelin** est un lease qui a perdu sa référence d'origine. Cela se produit lorsque :

- Le processus qui a créé le lease a été **arrêté ou supprimé** (pod terminé, job GitLab terminé, etc.)
- Le lease **existe toujours dans Vault** mais **aucun processus actif ne le gère**
- Le lease peut encore être **valide** (non expiré) mais n'est plus utilisé

#### Exemples de Leases Orphelins

1. **Pod Kubernetes supprimé**
   ```
   Scénario : Un pod a obtenu des credentials AWS via Vault injector
   → Le pod est supprimé (erreur, mise à jour, scale-down)
   → Le lease existe encore dans Vault mais le pod n'est plus là pour le renouveler
   → Résultat : Lease orphelin
   ```

2. **Pipeline GitLab terminée de manière inattendue**
   ```
   Scénario : Pipeline IAC a généré des secrets pour déployer l'infrastructure
   → La pipeline échoue ou est annulée avant la fin propre
   → Les scripts de nettoyage ne sont pas exécutés
   → Résultat : Leases orphelins qui restent dans Vault
   ```

3. **Pipeline CD qui échoue avant le nettoyage**
   ```
   Scénario : Pipeline CD génère des secrets pour déployer une application
   → Le déploiement échoue et la pipeline s'arrête
   → Le job de cleanup n'est jamais exécuté
   → Résultat : Leases orphelins
   ```

### Pourquoi gérer les Leases Orphelins ?

Les leases orphelins peuvent causer plusieurs problèmes :

- **Consommation de ressources** : Vault maintient ces leases en mémoire et en stockage
- **Risques de sécurité** : Des secrets valides peuvent rester actifs sans contrôle
- **Audit incomplet** : Difficulté à tracer l'origine et l'utilisation des secrets
- **Accumulation** : Au fil du temps, les leases orphelins s'accumulent et polluent Vault

### Comment cette Pipeline aide-t-elle ?

Cette pipeline permet de :

1. **Identifier** tous les leases existants dans Vault (actifs et orphelins)
2. **Filtrer** pour trouver spécifiquement les leases orphelins
3. **Nettoyer** les leases orphelins de manière sécurisée
4. **Auditer** via le fichier JSON généré qui contient tous les détails

### Cycle de vie d'un Lease

```
Création → Utilisation → Renouvellement → Expiration/Révocation
   ↓           ↓              ↓                    ↓
Pipeline    Pod/App      Vault/K8s          Cleanup
IAC/CD      utilise      renouvelle         automatique
```

**Cas normal :** Le lease est automatiquement renouvelé puis révoqué proprement

**Cas orphelin :** Le processus s'arrête, le lease n'est plus renouvelé mais reste actif jusqu'à expiration

## Détection des Leases Orphelins

Cette section explique le mécanisme technique utilisé par le script pour détecter et identifier les leases orphelins dans Vault.

### Mécanisme de Détection de Vault

Vault maintient automatiquement une **marque d'orphelin** (`orphan`) pour chaque lease. Cette marque est déterminée par Vault en fonction de la présence ou de l'absence d'un processus actif qui gère le lease.

#### Comment Vault détermine qu'un lease est orphelin ?

1. **Lors de la création du lease** : Vault enregistre une référence vers l'application ou le processus qui a demandé le lease
2. **Suivi du renouvellement** : Vault suit si le lease est régulièrement renouvelé par son propriétaire original
3. **Marque d'orphelin** : Si le processus d'origine disparaît (pod supprimé, pipeline terminée, etc.) et que le lease n'est plus renouvelé, Vault marque automatiquement le lease comme `orphan: true`

#### Propriété `orphan` dans l'API Vault

Lorsque vous interrogez un lease via l'API Vault `/sys/leases/lookup/{lease_path}`, la réponse inclut un champ `orphan` dans les métadonnées :

```json
{
  "data": {
    "lease_id": "aws/creds/myrole/abc123",
    "ttl": 3600,
    "renewable": true,
    "orphan": true,  // ← Ce champ indique si le lease est orphelin
    "issue_time": "2024-01-01T12:00:00Z",
    ...
  }
}
```

### Processus de Détection dans le Script

Le script `list-lease.sh` utilise un processus en plusieurs étapes pour détecter les leases orphelins :

#### Étape 1 : Exploration Récursive des Paths

Le script explore récursivement tous les paths de leases dans Vault :

```bash
# Utilise l'endpoint LIST pour obtenir les sous-chemins
curl --header "X-Vault-Token: $VAULT_TOKEN" \
     --request LIST \
     "$VAULT_ADDR/v1/sys/leases/subkeys/{path}"
```

**Processus :**
1. Commence à la racine : `/sys/leases/subkeys/`
2. Pour chaque path trouvé, fait un appel LIST récursif
3. Continue jusqu'à trouver des leases finaux (sans sous-chemins)

#### Étape 2 : Récupération des Détails de chaque Lease

Pour chaque lease trouvé, le script fait un appel à l'API `lookup` pour obtenir ses métadonnées complètes :

```bash
# Récupère les détails complets du lease
curl --header "X-Vault-Token: $VAULT_TOKEN" \
     "$VAULT_ADDR/v1/sys/leases/lookup/{lease_path}"
```

**Réponse exemple :**
```json
{
  "data": {
    "lease_id": "aws/creds/myrole/abc123",
    "path": "aws/creds/myrole",
    "ttl": 3600,
    "renewable": true,
    "orphan": true,  // ← Extrait ici
    "issue_time": "2024-01-01T12:00:00Z"
  }
}
```

#### Étape 3 : Extraction du Champ `orphan`

Le script extrait le champ `orphan` depuis la réponse de l'API et l'ajoute au fichier JSON :

```bash
# Dans get_lease_details()
local lease_json=$(echo "$lease_details" | jq -c --arg path "$path" --arg lease_id "$lease_id" --arg full_path "$lease_path" '{
    path: ($path | if . == "." then "" else . end),
    lease_id: $lease_id,
    full_path: $full_path,
    data: .data,
    orphan: (.data.orphan // false),  # ← Extraction du champ orphan
    renewable: (.data.renewable // false),
    ttl: (.data.ttl // 0),
    issue_time: (.data.issue_time // "")
}')
```

**Important :** Le script utilise `// false` comme valeur par défaut si le champ `orphan` n'existe pas dans la réponse (pour des raisons de compatibilité avec différentes versions de Vault).

#### Étape 4 : Stockage dans le Fichier JSON

Tous les leases sont stockés dans un fichier JSON avec leur statut d'orphelin :

```json
[
  {
    "path": "aws/creds/myrole",
    "lease_id": "abc123",
    "full_path": "aws/creds/myrole/abc123",
    "orphan": true,  // ← Statut d'orphelin
    "renewable": true,
    "ttl": 3600,
    "data": { ... }
  },
  {
    "path": "database/creds/myrole",
    "lease_id": "def456",
    "full_path": "database/creds/myrole/def456",
    "orphan": false,  // ← Lease normal (non orphelin)
    "renewable": true,
    "ttl": 7200,
    "data": { ... }
  }
]
```

#### Étape 5 : Comptage et Résumé

Le script compte automatiquement les leases orphelins :

```bash
# Compte le total de leases
total=$(jq '. | length' "$OUTPUT_FILE")

# Compte uniquement les leases orphelins
orphans=$(jq '[.[] | select(.orphan == true)] | length' "$OUTPUT_FILE")
```

**Sortie exemple :**
```
======================================
Résumé:
  Total de leases: 150
  Leases orphelins: 23
  Fichier de sortie: leases.json
======================================
```

### Filtrage des Leases Orphelins

Le script `destroy-lease.sh` utilise le fichier JSON généré pour filtrer les leases orphelins :

#### Option 1 : Filtrer avec `DESTROY_ORPHANS_ONLY`

Si `DESTROY_ORPHANS_ONLY=true`, le script filtre les leases orphelins :

```bash
if [ "$DESTROY_ORPHANS_ONLY" = "true" ]; then
    echo "Filtrage des leases orphelins uniquement..."
    filtered_file="${INPUT_FILE}.orphans.json"
    # Utilise jq pour filtrer uniquement les leases où orphan == true
    jq '[.[] | select(.orphan == true)]' "$INPUT_FILE" > "$filtered_file"
    leases_file="$filtered_file"
fi
```

#### Option 2 : Filtrer manuellement avec jq

Vous pouvez également filtrer manuellement le fichier JSON :

```bash
# Extraire uniquement les leases orphelins
jq '[.[] | select(.orphan == true)]' leases.json > orphans.json

# Compter les leases orphelins
jq '[.[] | select(.orphan == true)] | length' leases.json

# Lister les paths des leases orphelins
jq -r '.[] | select(.orphan == true) | .full_path' leases.json
```

### Limitations et Considérations

#### 1. **Temps de Détection**

Vault peut mettre un certain temps à marquer un lease comme orphelin après la disparition du processus. Cela dépend de :
- La fréquence de renouvellement attendue
- La configuration de Vault
- Le temps écoulé depuis la dernière interaction avec le lease

#### 2. **Leases en Renouvellement Automatique**

Certains leases peuvent être automatiquement renouvelés par Vault (par exemple, via Vault Agent) même si le processus original a disparu. Ces leases peuvent ne pas être marqués comme orphelins immédiatement.

#### 3. **Version de Vault**

Le comportement de la détection d'orphelins peut varier légèrement selon la version de Vault utilisée. Le script gère cela en utilisant une valeur par défaut `false` si le champ `orphan` n'est pas présent.

### Exemple Complet de Détection

Voici un exemple complet du processus de détection :

```bash
# 1. Le script explore récursivement
$ ./scripts/list-lease.sh
Exploration du path: (racine) (profondeur: 0)
Exploration du path: aws/creds (profondeur: 1)
Exploration du path: aws/creds/myrole (profondeur: 2)

# 2. Pour chaque lease, récupère les détails
  ✓ Lease trouvé: aws/creds/myrole/abc123
  ✓ Lease trouvé: aws/creds/myrole/def456
  ✓ Lease trouvé: database/creds/myrole/ghi789

# 3. Le script extrait le statut orphan de chaque lease
# (Vault détermine automatiquement ce statut)

# 4. Stocke dans le fichier JSON
# leases.json contient maintenant tous les leases avec leur statut orphan

# 5. Affiche le résumé
======================================
Résumé:
  Total de leases: 3
  Leases orphelins: 1
  Fichier de sortie: leases.json
======================================

# 6. Vous pouvez vérifier manuellement
$ jq '.[] | select(.orphan == true)' leases.json
{
  "path": "aws/creds/myrole",
  "lease_id": "abc123",
  "full_path": "aws/creds/myrole/abc123",
  "orphan": true,
  ...
}
```

### Vérification Manuelle d'un Lease Orphelin

Vous pouvez vérifier manuellement si un lease est orphelin :

**Via Vault CLI :**
```bash
vault read sys/leases/lookup/aws/creds/myrole/abc123 | grep orphan
```

**Via API (curl) :**
```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/leases/lookup/aws/creds/myrole/abc123" | \
  jq '.data.orphan'
```

**Résultat attendu :**
- `true` : Le lease est orphelin
- `false` : Le lease est actif (géré par un processus)

## Configuration

### Variables d'environnement requises

- `VAULT_ADDR` : Adresse du serveur Vault
  - **Vault HPROD** : Adresse pour les environnements `dev`, `int`, `qua` (ex: `https://vault-hprod.example.com:8200`)
  - **Vault PROD** : Adresse pour les environnements `pprod`, `prod` (ex: `https://vault-prod.example.com:8200`)
  - ⚠️ **Important** : Assurez-vous d'utiliser la bonne adresse selon l'environnement cible
- `VAULT_TOKEN` : Token d'authentification Vault avec les permissions nécessaires
  - Le token doit être valide pour le Vault spécifié (`hprod` ou `prod`)

### Variables d'environnement optionnelles

- `LEASE_LIST_PATHS` : Liste des paths séparés par des virgules à lister (ex: `path1,path2,aws/creds/role`)
  - Si non spécifié, liste tous les leases
- `DESTROY_ORPHANS_ONLY` : `true` pour détruire uniquement les leases orphelins, `false` pour tous (défaut: `false`)
- `OUTPUT_FILE` : Nom du fichier JSON de sortie (défaut: `leases.json`)

## Structure de la Pipeline

La pipeline se compose de trois stages principaux :

### Stage 0: `check_capabilities` (Pré-vérification)
- Job: `check_vault_capabilities`
- **Vérifie automatiquement** que le token Vault a toutes les permissions nécessaires
- Utilise le script `check-capabilities.sh` pour valider les capacités
- Si la vérification échoue, la pipeline s'arrête avant d'effectuer des opérations
- Fournit un rapport détaillé des permissions disponibles et manquantes

### Stage 1: `list_leases`
- Job: `list_vault_leases`
- **Dépend** du stage `check_capabilities` (ne s'exécute que si la vérification réussit)
- Liste tous les leases Vault selon les critères spécifiés
- Génère un artifact JSON (`leases.json`) avec tous les détails

### Stage 2: `destroy_leases`
- Job: `destroy_vault_leases` : Détruit tous les leases ou uniquement les orphelins selon `DESTROY_ORPHANS_ONLY`
- Job: `destroy_orphan_leases` : Job manuel optionnel pour détruire uniquement les leases orphelins
- **Dépendent** des stages `check_capabilities` et `list_vault_leases`

## Utilisation

> ⚠️ **Rappel Important** : Avant toute opération, consultez la section [Avertissement Important - Architecture et Criticité](#️-avertissement-important---architecture-et-criticité) pour comprendre l'impact potentiel sur votre infrastructure.

### Exemple 1: Lister tous les leases (HPROD - dev/int/qua)

```yaml
variables:
  VAULT_ADDR: "https://vault-hprod.example.com:8200"  # Vault HPROD
  VAULT_TOKEN: "${VAULT_TOKEN_HPROD}"  # Token pour Vault HPROD
```

### Exemple 1b: Lister tous les leases (PROD - pprod/prod)

```yaml
variables:
  VAULT_ADDR: "https://vault-prod.example.com:8200"  # Vault PROD
  VAULT_TOKEN: "${VAULT_TOKEN_PROD}"  # Token pour Vault PROD
```

### Exemple 2: Lister uniquement des paths spécifiques pour un namespace/codeAp

```yaml
# Pour un namespace spécifique avec codeAp AP12345 dans HPROD
variables:
  VAULT_ADDR: "https://vault-hprod.example.com:8200"
  VAULT_TOKEN: "${VAULT_TOKEN_HPROD}"
  LEASE_LIST_PATHS: "aws/creds/my-app-dev/AP12345,database/creds/my-app-dev/AP12345"
  
# Pour un namespace spécifique avec codeAp AP67890 dans PROD
variables:
  VAULT_ADDR: "https://vault-prod.example.com:8200"
  VAULT_TOKEN: "${VAULT_TOKEN_PROD}"
  LEASE_LIST_PATHS: "aws/creds/my-app-prod/AP67890,database/creds/my-app-prod/AP67890"
```

### Exemple 3: Lister et détruire uniquement les leases orphelins (RECOMMANDÉ)

⚠️ **CRITIQUE** : Avant d'exécuter cette pipeline, suivez la [procédure recommandée](#procédure-recommandée-avant-la-destruction) pour arrêter les pods et pipelines du namespace.

```yaml
# Exemple pour HPROD (environnement dev/int/qua)
variables:
  VAULT_ADDR: "https://vault-hprod.example.com:8200"
  VAULT_TOKEN: "${VAULT_TOKEN_HPROD}"
  LEASE_LIST_PATHS: "aws/creds/my-app-dev/AP12345"
  DESTROY_ORPHANS_ONLY: "true"  # ⚠️ RECOMMANDÉ : Ne détruire que les orphelins
```

### Exemple 4: Exécuter la destruction manuellement (sécurité)

Pour plus de sécurité, vous pouvez modifier la pipeline pour rendre la destruction manuelle en changeant :

```yaml
destroy_vault_leases:
  when: manual  # Au lieu de on_success
```

## Format du fichier JSON

Le fichier `leases.json` généré contient un tableau d'objets avec la structure suivante :

```json
[
  {
    "path": "aws/creds/myrole",
    "lease_id": "abc123",
    "full_path": "aws/creds/myrole/abc123",
    "orphan": false,
    "renewable": true,
    "ttl": 3600,
    "issue_time": "2024-01-01T12:00:00Z",
    "data": {
      // Données complètes du lease depuis Vault
    }
  }
]
```

## Scripts

### `scripts/check-capabilities.sh`
**Script de pré-vérification** qui vérifie que le token Vault dispose de toutes les capacités nécessaires avant d'exécuter les opérations sur les leases.

**Fonctionnalités :**
- Vérifie les capacités `list` et `read` sur `sys/leases/subkeys/*`
- Vérifie la capacité `read` sur `sys/leases/lookup/*`
- Vérifie la capacité `update` sur `sys/leases/revoke/*` (pour la destruction)
- Teste les opérations réelles (LIST, GET) pour confirmer les permissions
- Affiche les informations du token (policies, TTL)
- Fournit un rapport détaillé avec codes couleur

**Utilisation :**
```bash
export VAULT_ADDR="http://vault.example.com:8200"
export VAULT_TOKEN="votre-token"
./scripts/check-capabilities.sh
```

**Variables d'environnement optionnelles :**
- `CHECK_REVOKE_CAPABILITY` : `false` pour ne pas vérifier la capacité de révocation (par défaut: `true`)

**Exemple de sortie :**
```
==========================================
Vérification des capacités Vault
==========================================
Vault Address: http://vault.example.com:8200

Vérification: Capacité 'list' sur sys/leases/subkeys/ ... ✓ OK
  Capacités disponibles: list,read
Vérification: Capacité 'read' sur sys/leases/subkeys/ ... ✓ OK
  Capacités disponibles: list,read
...

✓ Tous les tests de capacités ont réussi
```

Ce script est **automatiquement exécuté** comme premier stage de la pipeline GitLab CI pour éviter les erreurs en cours d'exécution.

### `scripts/list-lease.sh`
Script bash qui liste les leases Vault. Il explore récursivement tous les paths ou uniquement les paths spécifiés dans `LEASE_LIST_PATHS`.

### `scripts/destroy-lease.sh`
Script bash qui détruit les leases. Il lit le fichier JSON généré par `list-lease.sh` et détruit tous les leases ou uniquement les orphelins selon `DESTROY_ORPHANS_ONLY`.

### `scripts/recover-leases.sh`
**Script d'aide à la récupération** après une suppression accidentelle de leases. Aide à évaluer l'impact et redémarrer les pods pour régénérer les secrets.

**Utilisation :**
```bash
export VAULT_ADDR="http://vault.example.com:8200"
./scripts/recover-leases.sh <namespace> [backup-file]
```

**Exemple :**
```bash
# Avec un fichier backup
./scripts/recover-leases.sh my-app-prod leases.json.backup-20240101-120000

# Sans fichier backup (le script cherchera automatiquement)
./scripts/recover-leases.sh my-app-prod
```

Ce script évalue l'impact, affiche les leases détruits (si backup disponible), et propose de redémarrer automatiquement les deployments pour régénérer les secrets. Pour plus de détails, consultez [`recuperation.md`](recuperation.md).

## Permissions Vault requises

Le token Vault doit avoir les permissions suivantes :

```
# Lister les leases
path "sys/leases/subkeys/*" {
  capabilities = ["list", "read"]
}

path "sys/leases/lookup/*" {
  capabilities = ["read"]
}

# Détruire les leases
path "sys/leases/revoke/*" {
  capabilities = ["update"]
}
```

## Notes de sécurité

> ⚠️ **ATTENTION CRITIQUE** : Avant d'utiliser cette pipeline, **LISEZ OBLIGATOIREMENT** la section [Avertissement Important - Architecture et Criticité](#️-avertissement-important---architecture-et-criticité). Cette opération peut **ARRÊTER TOUS LES PODS ET PIPELINES** utilisant le namespace concerné.

> 🔄 **Récupération après Suppression par Erreur** : Si des leases ont été supprimés par erreur, consultez le fichier [`recuperation.md`](recuperation.md) pour les procédures complètes de rollback et de récupération.

⚠️ **Attention** : La destruction de leases est une opération critique. Assurez-vous de :
- **Lire et suivre la procédure** décrite dans la section [Avertissement Important](#️-avertissement-important---architecture-et-criticité)
- **Arrêter tous les pods et pipelines** du namespace concerné avant la destruction
- Tester la pipeline sur un environnement de développement d'abord
- Vérifier le contenu du fichier JSON avant la destruction
- Configurer la destruction comme manuelle (`when: manual`) pour plus de sécurité
- Avoir une sauvegarde de Vault avant de détruire des leases
- **Ne détruire QUE les leases orphelins** lorsque possible (`DESTROY_ORPHANS_ONLY=true`)
- **Sauvegarder le fichier `leases.json`** avant la destruction (voir [`recuperation.md`](recuperation.md))

## Dépannage

### Aucun lease trouvé
- Vérifiez que `VAULT_TOKEN` a les permissions nécessaires
- Vérifiez que `VAULT_ADDR` est correct
- Vérifiez que les paths spécifiés dans `LEASE_LIST_PATHS` existent

### Erreurs lors de la destruction
- Vérifiez les logs pour voir quels leases ont échoué
- Certains leases peuvent avoir déjà été détruits
- Vérifiez que le token a la permission `update` sur `sys/leases/revoke/*`

### Suppression Accidentelle de Leases

Si des leases ont été supprimés par erreur :
- **Consultez immédiatement** [`recuperation.md`](recuperation.md) pour les procédures de récupération
- Utilisez le script `scripts/recover-leases.sh` pour faciliter la récupération
- Redémarrez les pods/containers pour régénérer les secrets
- Vérifiez que les nouveaux leases sont créés dans Vault


