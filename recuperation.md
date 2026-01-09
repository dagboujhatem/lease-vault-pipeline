# 🔄 Rollback et Récupération après Suppression par Erreur

## ⚠️ Limitations Importantes

**IMPORTANT : Vault ne permet PAS de restaurer directement un lease supprimé.**

Une fois qu'un lease est révoqué/détruit via l'API Vault :
- Le lease est **immédiatement et définitivement supprimé**
- Les secrets associés sont **invalidés immédiatement**
- **Aucune restauration automatique n'est possible**

## Stratégies de Prévention (AVANT la Destruction)

### 1. Sauvegarder le Fichier JSON Avant Destruction

**CRITIQUE** : Toujours sauvegarder le fichier `leases.json` avant de détruire des leases.

```bash
# Avant d'exécuter la destruction, sauvegarder le fichier
cp leases.json leases.json.backup-$(date +%Y%m%d-%H%M%S)

# Ou dans GitLab CI, créer un artifact sauvegardé
# Le fichier JSON est déjà un artifact, mais sauvegardez-le ailleurs aussi
```

### 2. Utiliser DESTROY_ORPHANS_ONLY=true

**Recommandation FORTE** : Toujours utiliser `DESTROY_ORPHANS_ONLY=true` sauf cas exceptionnel.

```yaml
variables:
  DESTROY_ORPHANS_ONLY: "true"  # Ne détruire QUE les orphelins
```

### 3. Utiliser la Destruction Manuelle

Dans `gitlab-ci.yaml`, la destruction est configurée comme manuelle :
```yaml
destroy_vault_leases:
  when: manual  # Nécessite une confirmation manuelle
```

### 4. Sauvegarde Automatique dans la Pipeline

**Recommandation** : Modifier le script `destroy-lease.sh` pour créer automatiquement une sauvegarde avant destruction.

## Procédures de Récupération (APRÈS une Suppression par Erreur)

Si des leases ont été supprimés par erreur, voici les procédures de récupération :

### Étape 1 : Évaluer l'Impact

```bash
# Vérifier quels pods sont affectés
kubectl get pods -n <namespace> --field-selector=status.phase!=Running

# Vérifier les erreurs dans les logs
kubectl logs -n <namespace> <pod-name> | grep -i "vault\|secret\|credential\|auth"

# Vérifier les événements Kubernetes
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Vérifier le statut des deployments
kubectl get deployments -n <namespace>

# Vérifier les statefulsets
kubectl get statefulsets -n <namespace>
```

### Étape 2 : Identifier les Secrets Perdus

Si vous avez sauvegardé le fichier `leases.json`, vous pouvez identifier ce qui a été supprimé :

```bash
# Lister tous les leases qui ont été détruits (si vous avez le backup)
cat leases.json.backup-YYYYMMDD-HHMMSS | jq '.[] | {
  path: .path,
  lease_id: .lease_id,
  full_path: .full_path,
  ttl: .ttl,
  renewable: .renewable,
  orphan: .orphan
}'

# Compter le nombre de leases détruits
cat leases.json.backup-YYYYMMDD-HHMMSS | jq '. | length'

# Lister uniquement les leases orphelins qui ont été détruits
cat leases.json.backup-YYYYMMDD-HHMMSS | jq '[.[] | select(.orphan == true)]'
```

### Étape 3 : Redémarrer les Pods pour Régénérer les Secrets

Les secrets dynamiques Vault sont régénérés automatiquement lorsque les pods sont redémarrés. Voici plusieurs méthodes :

#### Méthode 1 : Redéploiement des Deployments

```bash
# Forcer le redéploiement de tous les deployments du namespace
kubectl rollout restart deployment -n <namespace>

# Attendre que les pods soient redémarrés
kubectl rollout status deployment -n <namespace> --timeout=300s

# Vérifier le statut de chaque deployment
for deployment in $(kubectl get deployments -n <namespace> -o name); do
    echo "Vérification: $deployment"
    kubectl rollout status $deployment -n <namespace>
done
```

#### Méthode 2 : Suppression et Recréation des Pods

```bash
# Supprimer tous les pods (ils seront recréés automatiquement par les controllers)
kubectl delete pods -n <namespace> --all

# Vérifier que les nouveaux pods démarrent correctement
kubectl get pods -n <namespace> -w

# Surveiller les pods jusqu'à ce qu'ils soient tous Running
watch kubectl get pods -n <namespace>
```

#### Méthode 3 : Redémarrage via Scale Down/Up

```bash
# Scale down à 0 replicas pour tous les deployments
for deployment in $(kubectl get deployments -n <namespace> -o name); do
    echo "Scale down: $deployment"
    kubectl scale $deployment --replicas=0 -n <namespace>
done

# Attendre quelques secondes
sleep 10

# Scale up à nouveau avec le nombre original de replicas
# (À adapter selon vos besoins)
for deployment in $(kubectl get deployments -n <namespace> -o name); do
    # Récupérer le nombre original de replicas depuis un backup ou config
    replicas=2  # Adapter selon votre configuration
    echo "Scale up: $deployment à $replicas replicas"
    kubectl scale $deployment --replicas=$replicas -n <namespace>
done
```

#### Méthode 4 : Redémarrer les StatefulSets

```bash
# Pour les StatefulSets, il faut redémarrer chaque pod individuellement
# (les StatefulSets maintiennent un ordre spécifique)

# Méthode 1: Supprimer les pods un par un (ils seront recréés dans l'ordre)
kubectl delete pods -n <namespace> -l app=<app-label>

# Méthode 2: Utiliser kubectl rollout restart (si supporté)
kubectl rollout restart statefulset <statefulset-name> -n <namespace>
```

### Étape 4 : Vérifier que Vault Génère de Nouveaux Leases

Après le redémarrage des pods :

```bash
# Lister les nouveaux leases générés
export VAULT_ADDR="https://vault-hprod.example.com:8200"  # ou vault-prod
export VAULT_TOKEN="${VAULT_TOKEN}"

# Utiliser cette pipeline pour lister les nouveaux leases
# Les pods redémarrés devraient avoir créé de nouveaux leases
export LEASE_LIST_PATHS="<path-du-namespace>"
# Exécuter: stage list_leases

# Vérifier que les nouveaux leases sont présents
cat leases.json | jq '.[] | select(.path == "<path>") | {
  full_path: .full_path,
  issue_time: .issue_time,
  ttl: .ttl,
  orphan: .orphan
}'

# Compter les nouveaux leases générés
cat leases.json | jq '. | length'

# Comparer avec le backup (si disponible)
echo "Leases avant destruction: $(cat leases.json.backup-YYYYMMDD-HHMMSS | jq '. | length')"
echo "Leases après récupération: $(cat leases.json | jq '. | length')"
```

### Étape 5 : Vérifier le Fonctionnement des Applications

```bash
# Vérifier que les pods démarrent correctement
kubectl get pods -n <namespace>

# Vérifier que tous les pods sont en état Running
kubectl get pods -n <namespace> | grep -v Running && echo "⚠️ Certains pods ne sont pas Running" || echo "✓ Tous les pods sont Running"

# Vérifier les logs pour confirmer que les secrets sont accessibles
for pod in $(kubectl get pods -n <namespace> -o name); do
    echo "=== Logs de $pod ==="
    kubectl logs $pod -n <namespace> --tail=20 | grep -i "vault\|secret\|credential\|auth\|error" || echo "Aucune erreur liée à Vault détectée"
    echo ""
done

# Vérifier les health checks des applications
kubectl get pods -n <namespace> -o json | jq '.items[] | {
  name: .metadata.name,
  phase: .status.phase,
  ready: .status.conditions[] | select(.type=="Ready") | .status
}'

# Tester une fonctionnalité critique de l'application
# (par exemple, accès à une base de données, API externe, etc.)
kubectl exec -n <namespace> <pod-name> -- curl -s http://localhost:8080/health || echo "⚠️ Health check échoué"
```

## Récupération pour les Pipelines CI/CD

Si des pipelines ont été interrompues :

### 1. Vérifier l'État des Pipelines

```bash
# Dans GitLab, vérifier les pipelines en échec
# GitLab UI > CI/CD > Pipelines

# Via API GitLab
GITLAB_TOKEN="your-token"
GITLAB_URL="https://gitlab.example.com"
PROJECT_ID="123"

# Lister les pipelines récentes
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines?status=failed&per_page=10" | \
  jq '.[] | {id, status, ref, created_at}'
```

### 2. Identifier les Jobs en Échec

```bash
# Pour chaque pipeline en échec, identifier les jobs affectés
PIPELINE_ID="456"

curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/jobs" | \
  jq '.[] | select(.status=="failed") | {id, name, stage, status, failure_reason}'
```

### 3. Relancer les Pipelines

#### Via GitLab UI
1. Aller dans CI/CD > Pipelines
2. Identifier les pipelines qui ont échoué
3. Cliquer sur "Retry" pour relancer

#### Via GitLab API

```bash
# Relancer une pipeline spécifique
PIPELINE_ID="456"

curl -X POST \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/retry"

# Relancer un job spécifique
JOB_ID="789"

curl -X POST \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/jobs/$JOB_ID/retry"
```

### 4. Vérifier que les Nouveaux Secrets sont Générés

```bash
# Les pipelines IAC/CD génèrent normalement leurs propres secrets
# Vérifier que les nouveaux leases sont créés lors de l'exécution

# Après relance de la pipeline, lister les nouveaux leases
export LEASE_LIST_PATHS="<path-utilisé-par-la-pipeline>"
./scripts/list-lease.sh

# Vérifier que de nouveaux leases apparaissent
cat leases.json | jq '.[] | select(.issue_time > "<timestamp-de-la-destruction>")'
```

## Cas Particuliers : Secrets Statiques vs Dynamiques

### Secrets Dynamiques (AWS, Database, etc.)

**Cas le plus courant** : Les secrets sont régénérés automatiquement lors de la demande.

#### Secrets AWS (`aws/creds/role`)

```bash
# Un nouveau lease sera créé automatiquement lors de la prochaine demande
# Les pods redémarrés obtiendront automatiquement de nouveaux credentials AWS

# Vérifier que les nouveaux credentials sont générés
export LEASE_LIST_PATHS="aws/creds/<role>"
./scripts/list-lease.sh

cat leases.json | jq '.[] | {
  lease_id: .lease_id,
  issue_time: .issue_time,
  ttl: .ttl
}'
```

#### Secrets de Base de Données (`database/creds/role`)

```bash
# Un nouveau mot de passe sera généré automatiquement
# Les applications redémarrées obtiendront automatiquement de nouveaux mots de passe

# ⚠️ IMPORTANT : Les anciens mots de passe sont invalidés
# Assurez-vous que les applications peuvent se reconnecter avec les nouveaux credentials

# Vérifier que les nouveaux secrets de DB sont générés
export LEASE_LIST_PATHS="database/creds/<role>"
./scripts/list-lease.sh
```

**Action** : Redémarrer les pods suffit généralement, ils régénéreront automatiquement les secrets.

### Secrets Statiques ou Secrets Personnalisés

Si des secrets statiques ont été perdus :

```bash
# 1. Vérifier si le secret existe toujours dans Vault
vault kv get secret/data/<path>

# 2. Si le secret existe toujours dans Vault (seul le lease a été détruit)
# Les pods peuvent le relire directement après redémarrage

# 3. Si le secret lui-même n'existe plus, il faut le recréer manuellement
vault kv put secret/data/<path> key1=value1 key2=value2

# 4. Pour les secrets K/V v2
vault kv put secret/<path> key1=value1 key2=value2

# 5. Après recréation, redémarrer les pods pour qu'ils puissent lire les secrets
kubectl rollout restart deployment -n <namespace>
```

### Secrets Vault Injector (Kubernetes Sidecar)

Si vous utilisez Vault Injector dans Kubernetes :

```bash
# 1. Vérifier les annotations Vault sur les pods
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.metadata.annotations}' | jq '.'

# 2. Vérifier les sidecars Vault injectés
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n'

# 3. Vérifier les logs du sidecar Vault
kubectl logs <pod-name> -n <namespace> -c vault-agent

# 4. Si les secrets sont injectés via annotations, redémarrer les pods devrait régénérer les secrets
kubectl delete pod <pod-name> -n <namespace>

# 5. Le nouveau pod créé obtiendra automatiquement de nouveaux secrets via Vault Injector
```

## Script d'Aide à la Récupération

Voici un script utile pour faciliter la récupération :

```bash
#!/bin/bash
# Script de récupération après suppression accidentelle de leases
# Usage: ./scripts/recover-leases.sh <namespace> [backup-file]

set -e

NAMESPACE="${1:-}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
BACKUP_FILE="${2:-leases.json.backup}"

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [backup-file]"
    echo ""
    echo "Exemple:"
    echo "  $0 my-app-prod leases.json.backup-20240101-120000"
    exit 1
fi

echo "=========================================="
echo "Procédure de Récupération pour namespace: $NAMESPACE"
echo "=========================================="
echo ""

# 1. Évaluer l'impact
echo "1. Évaluation de l'impact..."
pod_count=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Pods dans le namespace: $pod_count"

deployment_count=$(kubectl get deployments -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Deployments dans le namespace: $deployment_count"

failed_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$failed_pods" -gt 0 ]; then
    echo "  ⚠️ Pods en erreur: $failed_pods"
else
    echo "  ✓ Aucun pod en erreur détecté"
fi

# 2. Afficher les leases détruits (si backup disponible)
echo ""
if [ -f "$BACKUP_FILE" ]; then
    echo "2. Leases détruits (selon backup: $BACKUP_FILE):"
    total_leases=$(jq '. | length' "$BACKUP_FILE" 2>/dev/null || echo "0")
    echo "  Total de leases dans le backup: $total_leases"
    
    orphan_leases=$(jq '[.[] | select(.orphan == true)] | length' "$BACKUP_FILE" 2>/dev/null || echo "0")
    echo "  Leases orphelins dans le backup: $orphan_leases"
    
    echo ""
    echo "  Premiers leases détruits:"
    jq -r '.[] | "    - \(.full_path) (orphan: \(.orphan // false))"' "$BACKUP_FILE" | head -10
    echo "    ... (voir $BACKUP_FILE pour la liste complète)"
else
    echo "2. ⚠️ Aucun fichier backup trouvé: $BACKUP_FILE"
    echo "   Recherche de fichiers backup..."
    ls -t leases.json.backup* 2>/dev/null | head -1 | while read backup; do
        echo "   Fichier trouvé: $backup"
        echo "   Utilisez: $0 $NAMESPACE $backup"
    done || echo "   Aucun fichier backup trouvé"
fi

# 3. Proposer la récupération
echo ""
echo "3. Procédure de récupération proposée:"
echo ""
echo "   a) Redémarrer les deployments (RECOMMANDÉ):"
echo "      kubectl rollout restart deployment -n $NAMESPACE"
echo ""
echo "   b) OU supprimer les pods:"
echo "      kubectl delete pods -n $NAMESPACE --all"
echo ""
echo "   c) Vérifier le statut:"
echo "      kubectl get pods -n $NAMESPACE"
echo "      kubectl rollout status deployment -n $NAMESPACE"
echo ""
echo "4. Après récupération, vérifier les nouveaux leases:"
if [ -n "$VAULT_ADDR" ]; then
    echo "   export VAULT_ADDR=\"$VAULT_ADDR\""
fi
echo "   export LEASE_LIST_PATHS=\"<path-du-namespace>\""
echo "   ./scripts/list-lease.sh"
echo ""
echo "=========================================="
echo "⚠️ Voulez-vous procéder à la récupération ?"
echo "=========================================="
echo ""
read -p "Redémarrer les deployments du namespace $NAMESPACE ? (yes/no): " confirm

if [ "$confirm" = "yes" ]; then
    echo ""
    echo "Redémarrage des deployments..."
    kubectl rollout restart deployment -n "$NAMESPACE"
    
    echo ""
    echo "Attente du redéploiement (timeout: 5 minutes)..."
    kubectl rollout status deployment -n "$NAMESPACE" --timeout=300s
    
    echo ""
    echo "✓ Récupération terminée"
    echo ""
    echo "Vérifiez maintenant que les pods sont Running:"
    echo "  kubectl get pods -n $NAMESPACE"
else
    echo ""
    echo "Récupération annulée. Exécutez manuellement les commandes ci-dessus."
fi
```

**Sauvegarder ce script dans** `scripts/recover-leases.sh` et le rendre exécutable :

```bash
chmod +x scripts/recover-leases.sh
```

## Checklist de Récupération

Utilisez cette checklist après une suppression accidentelle :

### Phase 1 : Évaluation Initiale
- [ ] ✅ Identifier les pods/namespaces affectés
- [ ] ✅ Vérifier si un fichier `leases.json.backup` existe
- [ ] ✅ Documenter quels leases ont été supprimés (si backup disponible)
- [ ] ✅ Évaluer l'impact sur les applications (quels services sont affectés)
- [ ] ✅ Vérifier l'état des deployments/statefulsets

### Phase 2 : Préparation
- [ ] ✅ Informer les équipes concernées
- [ ] ✅ Arrêter temporairement les déploiements automatiques (si nécessaire)
- [ ] ✅ Préparer les commandes de récupération
- [ ] ✅ Vérifier l'accès à Vault et Kubernetes

### Phase 3 : Récupération
- [ ] ✅ Redémarrer les pods (via rollout restart ou delete)
- [ ] ✅ Surveiller le redéploiement
- [ ] ✅ Vérifier que les nouveaux pods démarrent correctement
- [ ] ✅ Vérifier que de nouveaux leases sont générés dans Vault
- [ ] ✅ Tester le fonctionnement des applications

### Phase 4 : Vérification
- [ ] ✅ Vérifier les logs des applications pour confirmer l'accès aux secrets
- [ ] ✅ Tester les fonctionnalités critiques (accès DB, API externes, etc.)
- [ ] ✅ Vérifier les pipelines CI/CD (relancer si nécessaire)
- [ ] ✅ Comparer les nombres de leases avant/après (si backup disponible)

### Phase 5 : Post-Mortem
- [ ] ✅ Documenter l'incident et les actions de récupération
- [ ] ✅ Identifier la cause de l'erreur
- [ ] ✅ Mettre en place des mesures préventives
- [ ] ✅ Améliorer les procédures de sauvegarde si nécessaire

## Prévention Future

Pour éviter ce type d'incident :

### 1. Toujours utiliser `DESTROY_ORPHANS_ONLY=true`

```yaml
# Dans gitlab-ci.yaml
variables:
  DESTROY_ORPHANS_ONLY: "true"  # Ne détruire QUE les orphelins
```

### 2. Sauvegarder systématiquement `leases.json` avant destruction

Modifier le script `destroy-lease.sh` pour créer automatiquement une sauvegarde :

```bash
# À ajouter au début de destroy-lease.sh
if [ -f "$INPUT_FILE" ]; then
    BACKUP_FILE="${INPUT_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Création d'une sauvegarde: $BACKUP_FILE"
    cp "$INPUT_FILE" "$BACKUP_FILE"
    echo "Sauvegarde créée: $BACKUP_FILE"
fi
```

### 3. Utiliser la destruction manuelle (`when: manual`)

Dans `gitlab-ci.yaml` :
```yaml
destroy_vault_leases:
  when: manual  # Nécessite une confirmation manuelle
```

### 4. Valider la liste des leases avant destruction

Créer un stage de validation dans la pipeline :
```yaml
validate_leases_before_destroy:
  stage: validate
  script:
    - |
      echo "Vérification des leases à détruire..."
      total=$(jq '. | length' "$OUTPUT_FILE")
      orphans=$(jq '[.[] | select(.orphan == true)] | length' "$OUTPUT_FILE")
      echo "Total: $total, Orphelins: $orphans"
      if [ "$total" -gt 100 ]; then
        echo "⚠️ ATTENTION: Plus de 100 leases à détruire!"
        exit 1
      fi
  when: manual
```

### 5. Tester sur un environnement non-critique d'abord

- Toujours tester sur `dev` ou `int` avant d'appliquer sur `prod`
- Utiliser un namespace de test pour valider la procédure

### 6. Implémenter un mécanisme de backup automatique

Dans GitLab CI, ajouter un job qui archive le fichier JSON :
```yaml
archive_leases_backup:
  stage: list_leases
  script:
    - |
      BACKUP_FILE="leases-backup-$(date +%Y%m%d-%H%M%S).json"
      cp "$OUTPUT_FILE" "$BACKUP_FILE"
      echo "Sauvegarde créée: $BACKUP_FILE"
  artifacts:
    paths:
      - "leases-backup-*.json"
    expire_in: 30 days
```

## Contacts et Escalade

En cas de problème majeur :

1. **Administrateur Vault** : Pour les questions sur les secrets et leases
2. **Administrateur Kubernetes** : Pour les problèmes de redémarrage des pods
3. **Équipe DevOps/SRE** : Pour l'aide à la récupération
4. **Équipe Applicative** : Pour valider le fonctionnement des applications après récupération

## Ressources Utiles

- [Documentation Vault - Leases](https://www.vaultproject.io/docs/concepts/lease)
- [Documentation Kubernetes - Troubleshooting Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [GitLab CI/CD - Pipeline Recovery](https://docs.gitlab.com/ee/ci/pipelines/index.html)

