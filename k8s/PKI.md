# HashiCorp Vault PKI as a Service (PKIaaS)

Le moteur de secrets **PKI (Public Key Infrastructure)** de Vault permet de générer des certificats X.509 à la volée. Contrairement à une PKI traditionnelle où la génération d'un certificat peut prendre des jours, Vault transforme ce processus en un simple appel API.

## 🚀 Pourquoi utiliser Vault pour la PKI ?

1.  **Certificats éphémères** : Réduit radicalement la durée de vie des certificats (quelques heures ou jours au lieu de plusieurs années), ce qui limite l'impact en cas de compromission.
2.  **Automatisation (APIs)** : Intégration facile dans les pipelines CI/CD, Terraform, ou Kubernetes.
3.  **Révocation simplifiée** : Gestion native des listes de révocation (CRL) et support OCSP.
4.  **Coût réduit** : Pas besoin d'acheter chaque certificat auprès d'une autorité de certification (CA) publique pour les besoins internes (mTLS, APIs, etc.).

---

## 🏗️ Architecture Type

Dans une configuration recommandée, Vault ne doit pas être utilisé comme Root CA directement pour tout le cluster, mais plutôt structuré ainsi :

1.  **Root CA** : Générée et stockée hors ligne (ou dans un coffre Vault très sécurisé, peu accédé).
2.  **Intermediate CA** : Générée dans Vault et signée par la Root CA. C'est elle qui signera les certificats finaux.

---

## 🛠️ Étapes de Configuration (CLI)

### 1. Activer le moteur PKI
```bash
vault secrets enable pki
# Augmenter le TTL maximum (ex: 10 ans pour la Root CA)
vault secrets tune -max-lease-ttl=87600h pki
```

### 2. Générer la Root CA (Interne)
```bash
vault write -field=certificate pki/root/generate/internal \
    common_name="Mon Entreprise Root CA" \
    ttl=87600h > root_ca.crt
```

### 3. Configurer une Intermediate CA
Il est conseillé d'activer un nouveau mount pour l'intermédiaire :
```bash
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

# Générer une demande de signature (CSR)
vault write -format=json pki_int/intermediate/generate/internal \
    common_name="Mon Entreprise Intermediate CA" \
    | jq -r '.data.csr' > pki_intermediate.csr

# Faire signer le CSR par la Root CA
vault write -format=json pki/root/sign-intermediate \
    csr=@pki_intermediate.csr \
    format=pem_bundle \
    ttl="43800h" \
    | jq -r '.data.certificate' > intermediate.cert.pem

# Importer le certificat signé dans l'intermédiaire
vault write pki_int/intermediate/set-signed \
    certificate=@intermediate.cert.pem
```

### 4. Integration Kubernetes

Il existe 4 façons principales pour intégrer Vault PKI avec Kubernetes. Voici les détails et exemples pour **Nginx** et **Spring Boot** :

#### A. Init Container (One-shot)
- **Concept** : Un container temporaire (ex: `curl`) récupère le certificat avant le démarrage de l'application et le stocke dans un volume partagé (`emptyDir`).
- **Exemple Nginx** :
    ```yaml
    initContainers:
    - name: vault-init
      image: curlimages/curl:latest
      command: ["sh", "-c", "curl -d '{\"common_name\":\"nginx.local\"}' $VAULT_ADDR/v1/pki_int/issue/my-role > /etc/nginx/certs/cert.json"]
      volumeMounts:
      - name: certs
        mountPath: /etc/nginx/certs
    ```
- **Exemple Spring Boot** : L'init container peut transformer le certificat en Keystore JKS via `keytool` pour que Spring Boot le charge nativement.

#### B. Vault Agent Sidecar (Injection)
- **Concept** : L'injecteur ajoute automatiquement un container `vault-agent` qui s'occupe de l'authentification et de la récupération des certificats via des annotations.
- **Exemple Nginx** :
    ```yaml
    annotations:
      vault.hashicorp.com/agent-inject: "true"
      vault.hashicorp.com/agent-inject-secret-tls.crt: "pki_int/issue/my-role"
      vault.hashicorp.com/agent-inject-template-tls.crt: |
        {{- with secret "pki_int/issue/my-role" "common_name=nginx.local" -}}
        {{ .Data.certificate }}
        {{- end -}}
    ```
- **Exemple Spring Boot** : L'agent génère un fichier de clés que Spring Boot pointe via `server.ssl.certificate-private-key` (depuis Spring Boot 2.7+).

#### C. Vault Secrets Store CSI Driver
- **Concept** : Les secrets sont montés directement comme des fichiers par le driver CSI au niveau du nœud, sans sidecar.
- **Exemple Nginx** : Le volume CSI est monté dans `/etc/nginx/certs/`. Nginx lit les fichiers comme s'ils étaient locaux.
- **Exemple Spring Boot** : Montage du volume dans `/mnt/secrets-store`. Configuration `application.yaml` :
    ```yaml
    server:
      ssl:
        certificate: /mnt/secrets-store/tls.crt
        certificate-private-key: /mnt/secrets-store/tls.key
    ```

#### D. Cert-Manager (Le standard)
- **Concept** : Un contrôleur Kubernetes gère tout le cycle de vie (demande, renouvellement) et expose le certificat sous forme de `Secret` Kubernetes natif (`kubernetes.io/tls`).
- **Exemple Nginx** : L'Ingress Controller utilise directement le `Secret` créé par cert-manager.
- **Exemple Spring Boot** : On monte le `Secret` TLS comme un volume, ou on utilise le connecteur cert-manager pour importer le certificat dans le TrustStore Java de manière transparente.


---

## ☸️ Intégration Kubernetes (Cert-Manager)

C'est l'usage le plus courant en K8s. **Cert-Manager** délègue la signature des certificats à Vault.

### 1. Créer un Rôle Vault pour Cert-Manager
```bash
vault write pki_int/roles/k8s-dot-local \
    allowed_domains="cluster.local" \
    allow_subdomains=true \
    max_ttl="72h"
```

### 2. Configurer l'Issuer dans Kubernetes
```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
spec:
  vault:
    path: pki_int/sign/k8s-dot-local
    server: https://vault.default.svc.cluster.local:8200
    auth:
      kubernetes:
        role: cert-manager-role
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
```

---

## 📊 Avantages & Inconvénients

| ✅ Avantages | ❌ Inconvénients |
| :--- | :--- |
| **Agilité** : Délivrance de certificats en millisecondes. | **Complexité initiale** : Nécessite une bonne compréhension de la hiérarchie CA. |
| **Sécurité** : mTLS partout sans effort. | **Single Point of Failure** : Si Vault est indisponible, plus de nouveaux certificats. |
| **Audit** : Trace complète de qui a généré quel certificat. | **Consommation CPU** : La signature cryptographique est gourmande lors de pics de demande. |

---

## 💡 Cas d'usage : mTLS Service Mesh
Vault PKI est souvent utilisé comme backend pour **Istio** ou **Linkerd** pour automatiser la rotation des certificats mTLS entre les microservices sans intervention humaine.

---

## 🔄 Rotation des certificats

L'un des plus grands défis d'une PKI classique est la rotation (le renouvellement) des certificats avant leur expiration. Vault PKI, combiné à l'automatisation, résout ce problème.

### 1. Rotation via Cert-Manager (Kubernetes)
Dans Kubernetes, cert-manager surveille la date d'expiration de vos certificats. 
- **Seuil de renouvellement** : Par défaut, cert-manager tente de renouveler le certificat lorsqu'il reste **1/3 de sa durée de vie** (ou selon le paramètre `renewBefore` dans l'objet `Certificate`).
- **Processus** : 
    1. Cert-manager détecte que le certificat va expirer.
    2. Il envoie une nouvelle demande (CSR) à Vault via l'Issuer.
    3. Vault signe le nouveau certificat.
    4. Cert-manager met à jour le `Secret` Kubernetes contenant le certificat.

### 2. Alternatives sans Cert-Manager

Si tu n'utilises pas cert-manager, tu peux adapter les 3 solutions vues précédemment pour les secrets dynamiques :

#### A. Solution 1 : Init Container (Manuel)
- **Init Container** : Génère le premier certificat au démarrage du Pod.
- **Rotation** : Aucune rotation automatique. L'application doit soit :
    1. Redémarrer le Pod manuellement (ou via un cron).
    2. Implémenter la logique suivante dans son code :
    ```java
    // Exemple conceptuel Spring Boot
    while(true) {
        if (cert.expiresIn() < 1h) {
            newCert = vaultClient.pki().sign("my-role");
            updateSslContext(newCert);
        }
        sleep(30m);
    }
    ```

#### B. Solution 2 : Vault Agent Sidecar (Recommandé)
L'Agent gère tout. Tu définis simplement le secret.
- **Configuration** :
```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "my-app-role"
  # Demander un certificat à la PKI
  vault.hashicorp.com/agent-inject-secret-cert.pem: "pki_int/issue/my-role"
  # Template pour extraire uniquement le certificat
  vault.hashicorp.com/agent-inject-template-cert.pem: |
    {{- with secret "pki_int/issue/my-role" "common_name=my-app.local" -}}
    {{ .Data.certificate }}
    {{- end -}}
```
- **Mécanisme** : L'Agent surveille le TTL du certificat généré et relance le template automatiquement avant l'expiration.

#### C. Solution 3 : Secrets Store CSI Driver
- **Configuration** : Activer le polling dans le déploiement du driver.
```yaml
# Dans le Deployment ou Pod (Inline volume)
spec:
  volumes:
    - name: secrets-store-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "vault-pki-rotation"
```
- **SecretProviderClass** :
```yaml
parameters:
  objects: |
    - objectName: "tls.crt"
      secretPath: "pki_int/issue/my-role"
      secretKey: "certificate"
```
- **Rotation** : Le Driver CSI (via l'option `--enable-secret-rotation` du contrôleur) va rafraîchir le fichier sur le disque périodiquement.

### 3. Comparatif des solutions de rotation

| Solution | Automatisation | Complexité | Pré-requis | Rechargement App |
| :--- | :--- | :--- | :--- | :--- |
| **Cert-Manager** | ✅ Totale | Moyenne | CRDs + Issuer | Hot Reload / Restart |
| **Manual (Init)** | ❌ Nulle | Élevée | Aucun | Géré par l'App |
| **Vault Agent (Sidecar)** | ✅ Totale | Faible | Injector | Hot Reload / Restart |
| **CSI Driver** | ⚠️ Partielle | Moyenne | CSI + Provider | Hot Reload / Restart |

### 4. Prise en compte par l'application
Une fois le certificat renouvelé dans le Secret K8s, l'application doit le charger. Deux méthodes courantes :
- **Hot Reload --> (Rechargement à chaud)**: L'application surveille les changements sur le système de fichiers (via un volume mount) et recharge le certificat sans redémarrer.
    - **Exemple Nginx** : Un sidecar ou un script peut surveiller le fichier et lancer `nginx -s reload`.
    ```bash
    # Commande pour recharger Nginx sans coupure
    nginx -s reload
    ```
- **Restart (Reloader) --> (Redémarrage à froid)**: L'application est redémarrée par Kubernetes pour lire le nouveau certificat au démarrage.
    - **Exemple Spring Boot** : Souvent, Spring Boot lit ses certificats (Keystore/Truststore) au démarrage. Utiliser **Reloader** est la méthode la plus simple pour Kubernetes.
    ```yaml
    # Annotation Reloader sur le Deployment Spring Boot
    metadata:
      annotations:
        reloader.stakater.com/auto: "true"
    ```

### 5. Exemples concrets de rechargement

#### A. Cas Nginx (Rechargement à chaud)
Nginx supporte nativement le rechargement de sa configuration (et donc des certificats) sans interrompre les connexions en cours.
1. Vault Agent ou CSI Driver met à jour `/etc/nginx/certs/tls.crt`.
2. Un petit script "watcher" (souvent en sidecar) détecte la modification.
3. Il exécute `nginx -s reload`.

#### B. Cas Spring Boot (Redémarrage ou TrustStore dynamique)
1. **Méthode Standard (K3s/Reloader)** : C'est la plus robuste. Dès que Vault Agent met à jour le Secret, le Pod Spring Boot est recréé par Kubernetes. Cela garantit que toutes les connexions mTLS utilisent le nouveau certificat.
2. **Méthode Avancée (Programmation)** : Utiliser une bibliothèque comme `directory-watcher` pour recharger dynamiquement le `SSLContext` Java sans redémarrer la JVM. C'est plus complexe mais permet un vrai rechargement à chaud.

### 6. Rotation des autorités (Root/Intermediate)
- **Intermediate CA** : Doit être renouvelée périodiquement (ex: tous les ans). Il suffit de générer un nouveau CSR et de le faire signer par la Root.
- **Root CA** : Sa rotation est plus complexe car elle implique de mettre à jour le trust bundle de tous les clients. On utilise souvent une période de transition où deux Root CA sont considérées comme valides.
