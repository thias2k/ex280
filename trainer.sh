#!/usr/bin/env bash
#
# ex380-trainer.sh - Setup- & Grading-Framework fuer EX380-Uebungstasks
# Stil-kompatibel zum ex280-trainer: PASS/FAIL pro Check, Exit-Code,
# env-basierte Konfiguration, keine Abhaengigkeiten ausser oc + bash.
#
# Usage:
#   ./ex380-trainer.sh list              # Tasks + Themen anzeigen
#   ./ex380-trainer.sh setup <1-7>       # Ausgangszustand herstellen / resetten
#   ./ex380-trainer.sh grade <1-7|all>   # Loesung pruefen (wie der Grader)
#
# Voraussetzung: als cluster-admin eingeloggt (oc whoami).
# Lab-Infrastruktur (LDAP-, Backup-, Syslog-, Git-Server) kommt aus dem
# ROL-Classroom und wird NICHT von diesem Script provisioniert - die
# betroffenen Checks werden dann als SKIP markiert.
#
# Destruktive Resets (z.B. IdP-Config loeschen) nur mit FORCE=1.
#
set -uo pipefail

# ============================================================== Konfig ======
OC="${OC:-oc}"
FORCE="${FORCE:-0}"

# --- Task 1: Node Taints -----------------------------------------------------
T1_NS="${T1_NS:-apps-review}"
T1_DEPLOY="${T1_DEPLOY:-webapp}"
T1_REPLICAS="${T1_REPLICAS:-3}"
T1_IMAGE="${T1_IMAGE:-quay.io/redhattraining/hello-world-nginx:v1.0}"
T1_TAINT="${T1_TAINT:-maintenance=emergency:NoSchedule}"
WORKER_SEL="node-role.kubernetes.io/worker"

# --- Task 2: LDAP IdP ---------------------------------------------------------
T2_HOST="${T2_HOST:-idm.ocp4.example.com}"
T2_BINDDN="${T2_BINDDN:-uid=admin,cn=users,cn=accounts,dc=ocp4,dc=example,dc=com}"
T2_BINDPW="${T2_BINDPW:-RedHat123@!}"
T2_BASEDN="${T2_BASEDN:-cn=users,cn=accounts,dc=ocp4,dc=example,dc=com}"
T2_CA_URL="${T2_CA_URL:-http://idm.ocp4.example.com/ipa/config/ca.crt}"
T2_CM="${T2_CM:-ldap-ca}"
T2_SECRET="${T2_SECRET:-ldap-secret}"
T2_IDP_NAME="${T2_IDP_NAME:-ldap}"
T2_TESTUSER="${T2_TESTUSER:-ldapuser1}"

# --- Task 3: CSR / kubeconfig / cluster-reader --------------------------------
T3_USER="${T3_USER:-acme-auditor}"
T3_GROUP="${T3_GROUP:-acme-auditors}"
T3_DIR="${T3_DIR:-$HOME/acme-audit}"
T3_KUBECONFIG="${T3_KUBECONFIG:-$T3_DIR/kubeconfig-acme.config}"

# --- Task 4: OADP Restore + SCC ------------------------------------------------
T4_NS="${T4_NS:-mariadb-prod}"
T4_DEPLOY="${T4_DEPLOY:-mariadb}"
T4_SA="${T4_SA:-lynx}"
T4_SCC="${T4_SCC:-anyuid}"
T4_BACKUP="${T4_BACKUP:-mariadb-backup}"
T4_OADP_NS="${T4_OADP_NS:-openshift-adp}"
# Sim-Image, das unter restricted-v2 zuverlaessig crasht (root/Port 80):
T4_SIM_IMAGE="${T4_SIM_IMAGE:-docker.io/library/nginx:1.25}"

# --- Task 5: Logging (Vector/Syslog + EventRouter) -----------------------------
T5_NS="${T5_NS:-openshift-logging}"
T5_SYSLOG="${T5_SYSLOG:-tcp://syslog.example.com:514}"
T5_APPNAME="${T5_APPNAME:-openshift}"

# --- Task 6: GitOps Operator / ArgoCD ------------------------------------------
T6_NS="${T6_NS:-openshift-gitops}"
T6_GROUP="${T6_GROUP:-gitops-admins}"
T6_USER="${T6_USER:-admin}"
T6_CM="${T6_CM:-cluster-root-ca-bundle}"

# --- Task 7: MachineConfig via ArgoCD -------------------------------------------
T7_APP="${T7_APP:-machineconfig-motd-deploy}"
T7_PATH="${T7_PATH:-sshd-motd}"
T7_MC_MASTER="${T7_MC_MASTER:-71-master-sshd-motd}"
T7_MC_WORKER="${T7_MC_WORKER:-71-worker-sshd-motd}"
T7_SSH_CHECK="${T7_SSH_CHECK:-1}"   # 0 = Node-SSH-Check ueberspringen
T7_REPO="${T7_REPO:-http://git.example.com/ocp-gitops.git}"
T7_MOTD_URL="${T7_MOTD_URL:-http://materials.example.com/ssh.motd}"

# ============================================================ Helpers =======
if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'
  BOLD=$'\e[1m'; NC=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi

PASS=0; FAIL=0; SKIP=0

hdr()  { printf "\n%s== %s ==%s\n" "$BOLD$BLUE" "$*" "$NC"; }
info() { printf "%s  i %s%s\n" "$YELLOW" "$*" "$NC"; }
ok()   { printf "  %sPASS%s  %s\n" "$GREEN" "$NC" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  %sFAIL%s  %s\n" "$RED"   "$NC" "$1"; FAIL=$((FAIL+1)); }
skp()  { printf "  %sSKIP%s  %s\n" "$YELLOW" "$NC" "$1"; SKIP=$((SKIP+1)); }

# chk "Beschreibung" <kommando...>   -> PASS/FAIL je nach Exit-Code
chk() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
# chke "Beschreibung" 'shell-ausdruck'   -> via bash -c (fuer Pipes/Tests)
chke() {
  local desc="$1" expr="$2"
  if bash -c "$expr" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

jp() { $OC get "$@" 2>/dev/null; }   # Kurzform fuer oc get ... -o jsonpath

need_login() {
  if ! $OC whoami >/dev/null 2>&1; then
    echo "${RED}Nicht eingeloggt. Erst: oc login ...${NC}" >&2; exit 2
  fi
}

summary() {
  printf "\n%s---------------------------------------------%s\n" "$BOLD" "$NC"
  printf "%sErgebnis: %d PASS / %d FAIL / %d SKIP%s\n" \
    "$BOLD" "$PASS" "$FAIL" "$SKIP" "$NC"
  if [ "$FAIL" -eq 0 ]; then
    printf "%s>>> TASK BESTANDEN <<<%s\n" "$GREEN$BOLD" "$NC"; return 0
  else
    printf "%s>>> TASK NICHT BESTANDEN <<<%s\n" "$RED$BOLD" "$NC"; return 1
  fi
}

# ======================================================== Task 1 ============
task_1_text() {
cat <<EOF
  AUFGABE 1 (Pod Scheduling / Taints)
  Ein Kollege hat versehentlich Taints auf die Worker-Nodes angewendet;
  neue Pods bleiben Pending. Beheben Sie die Ursache. Erstellen Sie danach
  im Projekt '$T1_NS' ein Deployment '$T1_DEPLOY' mit Image
  '$T1_IMAGE' und $T1_REPLICAS Replicas. Alle Pods muessen laufen.
EOF
}

setup_1() {
  hdr "Setup Task 1 - Node Taints"
  $OC delete project "$T1_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  $OC adm taint nodes -l "$WORKER_SEL" "$T1_TAINT" --overwrite
  info "Worker-Nodes getaintet mit: $T1_TAINT (NoSchedule, evictet nichts)"
  task_1_text
}

grade_1() {
  hdr "Grade Task 1 - Node Taints"
  local key taints
  key=${T1_TAINT%%=*}; key=${key%%:*}
  taints=$($OC get nodes -l "$WORKER_SEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.taints[*].key}{"\n"}{end}' 2>/dev/null)
  chke "Trainings-Taint '$key' von allen Worker-Nodes entfernt" \
    "! grep -qw -- '$key' <<< '$taints'"
  if grep -Eq ': .+' <<< "$taints"; then
    info "Verbleibende Taint-Keys (Standard-Taints wie node-role.* sind ok):"
    grep -E ': .+' <<< "$taints" | sed 's/^/        /'
  fi
  chk  "Namespace $T1_NS existiert" $OC get ns "$T1_NS"
  chk  "Deployment $T1_DEPLOY existiert" $OC get deploy "$T1_DEPLOY" -n "$T1_NS"
  chke "$T1_REPLICAS Replicas ready" \
    "[ \"\$($OC get deploy $T1_DEPLOY -n $T1_NS -o jsonpath='{.status.readyReplicas}')\" = '$T1_REPLICAS' ]"
}

# ======================================================== Task 2 ============
task_2_text() {
cat <<EOF
  AUFGABE 2 (Authentication / LDAP IdP)
  Konfigurieren Sie den LDAP-Server des Labs als Identity Provider.
  Vorgaben:
    LDAP-Server:     $T2_HOST (ldaps, Port 636)
    Bind-DN:         $T2_BINDDN
    Bind-Passwort:   $T2_BINDPW
    Base-DN (Suche): $T2_BASEDN
    Login-Attribut:  uid   => URL-Format: ldaps://HOST/BASE_DN?uid
    CA-Zertifikat:   $T2_CA_URL
    ConfigMap:       $T2_CM  (Namespace openshift-config, Key ca.crt)
    Secret:          $T2_SECRET  (Namespace openshift-config, Key bindPassword)
    IdP-Name:        $T2_IDP_NAME (mappingMethod: claim)
  Verifikation: Login als '$T2_TESTUSER' muss funktionieren
  (danach wieder als admin einloggen!).
EOF
}

setup_2() {
  hdr "Setup Task 2 - LDAP IdP"
  if [ "$FORCE" = "1" ]; then
    $OC patch oauth cluster --type json \
      -p '[{"op":"remove","path":"/spec/identityProviders"}]' 2>/dev/null \
      && info "Alle identityProviders aus oauth/cluster entfernt (Reset)." \
      || info "Keine identityProviders vorhanden - nichts zu resetten."
  else
    info "Kein Reset ausgefuehrt (FORCE=1 setzen, um IdP-Config zu loeschen)."
  fi
  info "LDAP-Server selbst kommt aus dem ROL-Lab ($T2_HOST - per T2_* Env-Vars anpassbar)."
  task_2_text
}

grade_2() {
  hdr "Grade Task 2 - LDAP IdP"
  local url sec cm
  url=$(jp oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="LDAP")].ldap.url}')
  sec=$(jp oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="LDAP")].ldap.bindPassword.name}')
  cm=$(jp oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="LDAP")].ldap.ca.name}')

  chke "LDAP-IdP in oauth/cluster konfiguriert" "[ -n '$url' ]"
  chke "URL nutzt ldaps://" "case '$url' in ldaps://*) true;; *) false;; esac"
  chke "URL endet auf ?uid" "case '$url' in *'?uid') true;; *) false;; esac"
  if [ -n "$sec" ]; then
    chke "Secret '$sec' in openshift-config mit Key bindPassword" \
      "[ -n \"\$($OC get secret $sec -n openshift-config -o jsonpath='{.data.bindPassword}' 2>/dev/null)\" ]"
  else
    bad "bindPassword-Secret referenziert"
  fi
  if [ -n "$cm" ]; then
    chke "ConfigMap '$cm' in openshift-config mit Key ca.crt" \
      "[ -n \"\$($OC get cm $cm -n openshift-config -o jsonpath='{.data.ca\\.crt}' 2>/dev/null)\" ]"
  else
    bad "CA-ConfigMap referenziert"
  fi
  chke "ClusterOperator authentication: Available=True" \
    "[ \"\$($OC get co authentication -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}')\" = 'True' ]"
  chke "ClusterOperator authentication: Degraded=False" \
    "[ \"\$($OC get co authentication -o jsonpath='{.status.conditions[?(@.type==\"Degraded\")].status}')\" = 'False' ]"
  info "Manuell zusaetzlich testen: oc login -u $T2_TESTUSER (danach wieder als admin einloggen!)"
}

# ======================================================== Task 3 ============
task_3_text() {
cat <<EOF
  AUFGABE 3 (Security / Zertifikats-Auth + kubeconfig)
  Die Firma ACME auditiert den Cluster. Richten Sie einen
  zertifikatsbasierten, rein lesenden Zugang ein.
  Vorgaben:
    Arbeitsverzeichnis: $T3_DIR
    Benutzer (CN):      $T3_USER
    Key-/CSR-Datei:     tls.key / ${T3_USER}.csr (RSA 4096)
    CSR-Objekt/Signer:  $T3_USER / kubernetes.io/kube-apiserver-client
    Gruppe:             $T3_GROUP (Mitglied: $T3_USER)
    Rolle:              cluster-reader (clusterweit, nur lesen)
    kubeconfig:         $T3_KUBECONFIG (Zertifikate embedded)
    API-Server:         \$(oc whoami --show-server)
EOF
}

setup_3() {
  hdr "Setup Task 3 - CSR / kubeconfig"
  $OC delete csr "$T3_USER" --ignore-not-found
  $OC adm policy remove-cluster-role-from-group cluster-reader "$T3_GROUP" 2>/dev/null
  $OC delete group "$T3_GROUP" --ignore-not-found
  info "Cluster-Objekte (csr, group, binding) entfernt."
  if [ "$FORCE" = "1" ] && [ -d "$T3_DIR" ]; then
    rm -rf "$T3_DIR"; info "$T3_DIR geloescht."
  else
    info "Lokales Verzeichnis $T3_DIR bleibt (FORCE=1 zum Loeschen)."
  fi
  task_3_text
}

grade_3() {
  hdr "Grade Task 3 - CSR / kubeconfig"
  chke "CSR '$T3_USER' approved + Zertifikat ausgestellt" \
    "[ -n \"\$($OC get csr $T3_USER -o jsonpath='{.status.certificate}' 2>/dev/null)\" ]"
  chke "Gruppe '$T3_GROUP' enthaelt '$T3_USER'" \
    "$OC get group $T3_GROUP -o jsonpath='{.users}' | grep -qw $T3_USER"
  chke "cluster-reader an Gruppe '$T3_GROUP' gebunden" \
    "$OC get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name==\"cluster-reader\")]}{.subjects[*].name}{\" \"}{end}' | grep -qw $T3_GROUP"
  if [ -f "$T3_KUBECONFIG" ]; then
    chke "kubeconfig: whoami = $T3_USER" \
      "[ \"\$($OC --kubeconfig=$T3_KUBECONFIG whoami 2>/dev/null)\" = '$T3_USER' ]"
    chk  "kubeconfig: Lesen erlaubt (get nodes)" \
      $OC --kubeconfig="$T3_KUBECONFIG" get nodes
    chke "kubeconfig: Schreiben verboten (can-i create pods -A = no)" \
      "! $OC --kubeconfig=$T3_KUBECONFIG auth can-i create pods -A"
    chke "kubeconfig: Zertifikate embedded (keine Pfad-Referenzen)" \
      "! grep -qE 'client-certificate:|client-key:|certificate-authority:' $T3_KUBECONFIG"
  else
    bad "kubeconfig '$T3_KUBECONFIG' existiert (ggf. T3_KUBECONFIG=... setzen)"
  fi
}

# ======================================================== Task 4 ============
task_4_text() {
cat <<EOF
  AUFGABE 4 (OADP Restore + SCC)
  Stellen Sie ein Projekt aus einem vorhandenen Backup wieder her und
  beheben Sie den anschliessenden CrashLoop der Datenbank.
  Vorgaben:
    OADP-Namespace:     $T4_OADP_NS
    Backup (existiert): $T4_BACKUP
    Restore-Objekt:     mariadb-restore  (Phase: Completed)
    App-Projekt:        $T4_NS
    Deployment:         $T4_DEPLOY
    ServiceAccount:     $T4_SA
    SCC:                $T4_SCC
EOF
}

setup_4() {
  hdr "Setup Task 4 - OADP + SCC"
  if $OC get ns "$T4_OADP_NS" >/dev/null 2>&1; then
    $OC delete restore --all -n "$T4_OADP_NS" --ignore-not-found >/dev/null 2>&1
    info "Alte Restore-CRs geloescht. Backup '$T4_BACKUP' muss vom Lab kommen"
    info "(ROL: 'lab start backup-restore' o.ae.)."
  else
    info "Kein OADP installiert - Restore-Teil wird beim Grading uebersprungen."
    info "SIMULATION des SCC-Teils wird eingerichtet:"
    $OC delete project "$T4_NS" --ignore-not-found --wait=true >/dev/null 2>&1
    sleep 2
    $OC new-project "$T4_NS" >/dev/null 2>&1 || $OC project "$T4_NS" >/dev/null
    $OC create deployment "$T4_DEPLOY" --image="$T4_SIM_IMAGE" -n "$T4_NS"
    info "Deployment '$T4_DEPLOY' ($T4_SIM_IMAGE) crasht unter restricted-v2"
    info "-> Fix: sa '$T4_SA' + SCC '$T4_SCC' + oc set serviceaccount"
  fi
  task_4_text
}

grade_4() {
  hdr "Grade Task 4 - OADP + SCC"
  if $OC get ns "$T4_OADP_NS" >/dev/null 2>&1; then
    chke "Restore aus Backup '$T4_BACKUP' mit Phase Completed" \
      "$OC get restore -n $T4_OADP_NS -o jsonpath='{range .items[*]}{.spec.backupName}{\" \"}{.status.phase}{\"\\n\"}{end}' | grep -q '^$T4_BACKUP Completed'"
  else
    skp "OADP nicht installiert - Restore-Check uebersprungen"
  fi
  chk  "ServiceAccount '$T4_SA' existiert in $T4_NS" \
    $OC get sa "$T4_SA" -n "$T4_NS"
  chke "Deployment nutzt serviceAccountName=$T4_SA" \
    "[ \"\$($OC get deploy $T4_DEPLOY -n $T4_NS -o jsonpath='{.spec.template.spec.serviceAccountName}')\" = '$T4_SA' ]"
  chke "SCC '$T4_SCC' der SA zugewiesen (CRB system:openshift:scc:$T4_SCC)" \
    "$OC get clusterrolebinding system:openshift:scc:$T4_SCC -o jsonpath='{range .subjects[*]}{.namespace}{\"/\"}{.name}{\"\\n\"}{end}' | grep -qx '$T4_NS/$T4_SA'"
  chke "Laufender Pod hat Annotation openshift.io/scc=$T4_SCC" \
    "$OC get pods -n $T4_NS -o jsonpath='{.items[*].metadata.annotations.openshift\\.io/scc}' | grep -qw $T4_SCC"
  chke "Alle Pods des Deployments ready" \
    "[ \"\$($OC get deploy $T4_DEPLOY -n $T4_NS -o jsonpath='{.status.readyReplicas}')\" = \"\$($OC get deploy $T4_DEPLOY -n $T4_NS -o jsonpath='{.spec.replicas}')\" ]"
}

# ======================================================== Task 5 ============
task_5_text() {
cat <<EOF
  AUFGABE 5 (Logging: Vector -> Syslog + EventRouter)
  Installieren Sie OpenShift Logging und forwarden Sie alle drei
  Log-Typen an den Syslog-Server des Labs.
  Vorgaben:
    Operator/Namespace:    Red Hat OpenShift Logging / $T5_NS
    Collector:             vector
    Syslog-Ziel (alle):    $T5_SYSLOG
    Output application:    Name apps-syslog,  appName $T5_APPNAME, procID app
    Output infrastructure: Name infra-syslog, appName $T5_APPNAME, procID infra
    Output audit:          Name audit-syslog, appName $T5_APPNAME, procID audit
    Pipelines:             je Log-Typ eine eigene Pipeline auf den Output
    EventRouter:           Deployment eventrouter in $T5_NS (Doku-Template)
EOF
}

setup_5() {
  hdr "Setup Task 5 - Logging"
  if [ "$FORCE" = "1" ]; then
    $OC delete clusterlogforwarder.logging.openshift.io instance -n "$T5_NS" --ignore-not-found 2>/dev/null
    $OC delete clusterlogging.logging.openshift.io instance -n "$T5_NS" --ignore-not-found 2>/dev/null
    $OC delete clusterlogforwarder.observability.openshift.io --all -n "$T5_NS" --ignore-not-found 2>/dev/null
    $OC delete deploy eventrouter -n "$T5_NS" --ignore-not-found 2>/dev/null
    info "Logging-CRs + EventRouter entfernt (Operator bleibt installiert)."
  else
    info "Kein Reset (FORCE=1 setzen, um CLF/CL/EventRouter zu loeschen)."
  fi
  info "Syslog-Zielserver kommt aus dem ROL-Lab."
  task_5_text
}

grade_5() {
  hdr "Grade Task 5 - Logging"
  local api=""
  if $OC get crd clusterlogforwarders.observability.openshift.io >/dev/null 2>&1 \
     && [ -n "$(jp clusterlogforwarder.observability.openshift.io -n "$T5_NS" -o name)" ]; then
    api="6x"
  elif $OC get crd clusterlogforwarders.logging.openshift.io >/dev/null 2>&1; then
    api="5x"
  fi

  case "$api" in
    5x)
      info "Logging 5.x API erkannt (logging.openshift.io/v1)"
      chke "ClusterLogging 'instance' mit collection.type=vector" \
        "[ \"\$($OC get clusterlogging.logging.openshift.io instance -n $T5_NS -o jsonpath='{.spec.collection.type}' 2>/dev/null)\" = 'vector' ]"
      chk  "ClusterLogForwarder 'instance' existiert" \
        $OC get clusterlogforwarder.logging.openshift.io instance -n "$T5_NS"
      local pipes outs
      pipes=$(jp clusterlogforwarder.logging.openshift.io instance -n "$T5_NS" -o jsonpath='{.spec.pipelines[*].inputRefs}')
      outs=$(jp clusterlogforwarder.logging.openshift.io instance -n "$T5_NS" -o jsonpath='{.spec.outputs[*].type}')
      chke "Pipeline fuer application vorhanden"    "grep -qw application    <<< '$pipes'"
      chke "Pipeline fuer infrastructure vorhanden" "grep -qw infrastructure <<< '$pipes'"
      chke "Pipeline fuer audit vorhanden"          "grep -qw audit          <<< '$pipes'"
      chke "Alle Outputs vom Typ syslog" \
        "[ -n '$outs' ] && ! grep -vqw syslog <<< '$outs'"
      chke "Output-URLs nutzen tcp://" \
        "$OC get clusterlogforwarder.logging.openshift.io instance -n $T5_NS -o jsonpath='{.spec.outputs[*].url}' | grep -q 'tcp://'"
      ;;
    6x)
      info "Logging 6.x API erkannt (observability.openshift.io/v1)"
      chke "ClusterLogForwarder vorhanden" \
        "[ -n \"\$($OC get clusterlogforwarder.observability.openshift.io -n $T5_NS -o name)\" ]"
      chke "Pipelines decken application/infrastructure/audit ab" \
        "p=\$($OC get clusterlogforwarder.observability.openshift.io -n $T5_NS -o jsonpath='{.items[*].spec.pipelines[*].inputRefs}'); grep -qw application <<<\"\$p\" && grep -qw infrastructure <<<\"\$p\" && grep -qw audit <<<\"\$p\""
      chke "Outputs vom Typ syslog" \
        "$OC get clusterlogforwarder.observability.openshift.io -n $T5_NS -o jsonpath='{.items[*].spec.outputs[*].type}' | grep -qw syslog"
      ;;
    *)
      skp "Kein Logging-Operator/CRD gefunden - Task nicht bewertbar"
      return
      ;;
  esac

  chke "Collector-Pods laufen (DaemonSet ready == desired)" \
    "d=\$($OC get ds collector -n $T5_NS -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null); r=\$($OC get ds collector -n $T5_NS -o jsonpath='{.status.numberReady}' 2>/dev/null); [ -n \"\$d\" ] && [ \"\$d\" = \"\$r\" ]"
  chke "EventRouter-Deployment ready" \
    "[ \"\$($OC get deploy eventrouter -n $T5_NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" = '1' ]"
  info "Endkontrolle im Lab: auf dem Syslog-Server pruefen, ob Logs ankommen"
  info "(z.B. ssh utility 'ls -la /var/log/...')."
}

# ======================================================== Task 6 ============
task_6_text() {
cat <<EOF
  AUFGABE 6 (GitOps Operator / ArgoCD)
  Installieren und konfigurieren Sie OpenShift GitOps.
  Vorgaben:
    Operator-NS/Channel: openshift-gitops-operator / latest
    Instanz (CR):        argocd/openshift-gitops in $T6_NS
    Route:               TLS-Termination reencrypt
    Gruppe/Mitglied:     $T6_GROUP / $T6_USER
    ArgoCD-RBAC:         NUR 'g, $T6_GROUP, role:admin' (scopes '[groups]')
    ConfigMap:           $T6_CM mit Label
                         config.openshift.io/inject-trusted-cabundle=true
    Mount (Repo-Server): /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
                         (subPath: ca-bundle.crt)
EOF
}

setup_6() {
  hdr "Setup Task 6 - GitOps/ArgoCD"
  if [ "$FORCE" = "1" ]; then
    $OC delete group "$T6_GROUP" --ignore-not-found
    $OC delete cm "$T6_CM" -n "$T6_NS" --ignore-not-found 2>/dev/null
    info "Gruppe + ConfigMap entfernt. ArgoCD-CR-Anpassungen (route/rbac/repo)"
    info "manuell zuruecksetzen: oc edit argocd openshift-gitops -n $T6_NS"
  else
    info "Kein Reset (FORCE=1 fuer Gruppe/ConfigMap-Loeschung)."
  fi
  task_6_text
}

grade_6() {
  hdr "Grade Task 6 - GitOps/ArgoCD"
  if ! $OC get ns "$T6_NS" >/dev/null 2>&1; then
    skp "Namespace $T6_NS fehlt - Operator nicht installiert?"
    return
  fi
  chke "Operator-Namespace openshift-gitops-operator existiert" \
    "$OC get ns openshift-gitops-operator"
  chke "ArgoCD-CR: spec.server.route.enabled=true" \
    "[ \"\$($OC get argocd openshift-gitops -n $T6_NS -o jsonpath='{.spec.server.route.enabled}')\" = 'true' ]"
  chke "ArgoCD-CR: route.tls.termination=reencrypt" \
    "[ \"\$($OC get argocd openshift-gitops -n $T6_NS -o jsonpath='{.spec.server.route.tls.termination}')\" = 'reencrypt' ]"
  chke "Route openshift-gitops-server: termination=reencrypt" \
    "[ \"\$($OC get route openshift-gitops-server -n $T6_NS -o jsonpath='{.spec.tls.termination}')\" = 'reencrypt' ]"
  chke "Gruppe '$T6_GROUP' enthaelt '$T6_USER'" \
    "$OC get group $T6_GROUP -o jsonpath='{.users}' | grep -qw $T6_USER"
  local pol
  pol=$(jp argocd openshift-gitops -n "$T6_NS" -o jsonpath='{.spec.rbac.policy}')
  chke "RBAC-Policy enthaelt: g, $T6_GROUP, role:admin" \
    "grep -Eq 'g,[[:space:]]*$T6_GROUP,[[:space:]]*role:admin' <<< '$pol'"
  chke "RBAC-Policy: keine anderen Gruppen mit role:admin" \
    "! grep -E 'g,' <<< '$pol' | grep -v '$T6_GROUP' | grep -q 'role:admin'"
  chke "RBAC scopes enthaelt groups" \
    "$OC get argocd openshift-gitops -n $T6_NS -o jsonpath='{.spec.rbac.scopes}' | grep -q groups"
  chke "ConfigMap '$T6_CM' mit inject-trusted-cabundle-Label" \
    "[ \"\$($OC get cm $T6_CM -n $T6_NS -o jsonpath='{.metadata.labels.config\\.openshift\\.io/inject-trusted-cabundle}')\" = 'true' ]"
  chke "ConfigMap wurde injiziert (data.ca-bundle.crt nicht leer)" \
    "[ -n \"\$($OC get cm $T6_CM -n $T6_NS -o jsonpath='{.data.ca-bundle\\.crt}')\" ]"
  chke "Repo-Server: volumeMount auf tls-ca-bundle.pem" \
    "$OC get argocd openshift-gitops -n $T6_NS -o jsonpath='{.spec.repo.volumeMounts[*].mountPath}' | grep -q 'tls-ca-bundle.pem'"
  chke "Repo-Server: subPath=ca-bundle.crt gesetzt" \
    "$OC get argocd openshift-gitops -n $T6_NS -o jsonpath='{.spec.repo.volumeMounts[*].subPath}' | grep -q 'ca-bundle.crt'"
  chke "Repo-Server-Deployment ready" \
    "[ \"\$($OC get deploy openshift-gitops-repo-server -n $T6_NS -o jsonpath='{.status.readyReplicas}')\" = '1' ]"
}

# ======================================================== Task 7 ============
task_7_text() {
cat <<EOF
  AUFGABE 7 (MachineConfig via ArgoCD)
  Verteilen Sie /etc/motd GitOps-getrieben auf ALLE Nodes.
  Vorgaben:
    Git-Repo:        $T7_REPO (Credentials laut Lab)
    Pfad im Repo:    $T7_PATH  (kustomization.yaml ergaenzen!)
    MOTD-Quelle:     $T7_MOTD_URL
    Dateien:         ${T7_MC_MASTER}.yaml (role: master)
                     ${T7_MC_WORKER}.yaml (role: worker)
    Datei auf Node:  /etc/motd, mode 0444, overwrite: true, base64-Inhalt
    Ignition:        neueste Version des Clusters (aus MC 00-master)
    ArgoCD-Repo:     mit 'Skip server verification' registrieren
    Application:     $T7_APP, Project default,
                     Path $T7_PATH, Sync Policy MANUAL, danach syncen
    Verifikation:    /etc/motd auf allen Nodes, Permissions 444
EOF
}

setup_7() {
  hdr "Setup Task 7 - MachineConfig via ArgoCD"
  if [ "$FORCE" = "1" ]; then
    $OC delete application "$T7_APP" -n "$T6_NS" --ignore-not-found 2>/dev/null
    $OC delete mc "$T7_MC_MASTER" "$T7_MC_WORKER" --ignore-not-found 2>/dev/null \
      && info "ACHTUNG: MC-Loeschung triggert Node-Rollout (bis ~15 min)."
    info "Application + MachineConfigs entfernt."
  else
    info "Kein Reset (FORCE=1 fuer App-/MC-Loeschung; triggert Node-Reboots!)."
  fi
  info "Git-Server + motd-URL kommen aus dem ROL-Lab."
  task_7_text
}

grade_7() {
  hdr "Grade Task 7 - MachineConfig via ArgoCD"
  chk  "ArgoCD Application '$T7_APP' existiert" \
    $OC get application "$T7_APP" -n "$T6_NS"
  chke "Application nutzt Pfad '$T7_PATH'" \
    "[ \"\$($OC get application $T7_APP -n $T6_NS -o jsonpath='{.spec.source.path}')\" = '$T7_PATH' ]"
  chke "Sync Policy = Manual (kein automated)" \
    "[ -z \"\$($OC get application $T7_APP -n $T6_NS -o jsonpath='{.spec.syncPolicy.automated}')\" ]"
  chke "Application ist Synced" \
    "[ \"\$($OC get application $T7_APP -n $T6_NS -o jsonpath='{.status.sync.status}')\" = 'Synced' ]"
  chke "Application ist Healthy" \
    "[ \"\$($OC get application $T7_APP -n $T6_NS -o jsonpath='{.status.health.status}')\" = 'Healthy' ]"

  local role mc
  for role in master worker; do
    mc="71-${role}-sshd-motd"
    chk  "MachineConfig $mc existiert" $OC get mc "$mc"
    chke "$mc: Label role=$role" \
      "[ \"\$($OC get mc $mc -o jsonpath='{.metadata.labels.machineconfiguration\\.openshift\\.io/role}')\" = '$role' ]"
    chke "$mc: Datei /etc/motd definiert" \
      "$OC get mc $mc -o jsonpath='{.spec.config.storage.files[*].path}' | grep -q '/etc/motd'"
    chke "$mc: mode=0444 (dezimal 292)" \
      "$OC get mc $mc -o jsonpath='{.spec.config.storage.files[*].mode}' | grep -qw 292"
    chke "$mc: overwrite=true" \
      "$OC get mc $mc -o jsonpath='{.spec.config.storage.files[*].overwrite}' | grep -qw true"
    chke "$mc: Content als base64-data-URL" \
      "$OC get mc $mc -o jsonpath='{.spec.config.storage.files[*].contents.source}' | grep -q '^data:text/plain'"
    chke "MCP $role: Updated=True" \
      "[ \"\$($OC get mcp $role -o jsonpath='{.status.conditions[?(@.type==\"Updated\")].status}')\" = 'True' ]"
    chke "MCP $role: Degraded=False" \
      "[ \"\$($OC get mcp $role -o jsonpath='{.status.conditions[?(@.type==\"Degraded\")].status}')\" = 'False' ]"
  done

  if [ "$T7_SSH_CHECK" = "1" ]; then
    local node perm
    node=$($OC get nodes -l "$WORKER_SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$node" ]; then
      perm=$(timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
             "core@$node" 'stat -c %a /etc/motd' 2>/dev/null)
      if [ "$perm" = "444" ]; then
        ok "Node $node: /etc/motd vorhanden mit 444"
      elif [ -z "$perm" ]; then
        skp "SSH-Check auf $node nicht moeglich (T7_SSH_CHECK=0 zum Abschalten)"
      else
        bad "Node $node: /etc/motd Permissions = $perm (erwartet 444)"
      fi
    else
      skp "Kein Worker-Node gefunden fuer SSH-Check"
    fi
  fi
}

# ============================================================ Dispatch ======
list_tasks() {
cat <<EOF
${BOLD}EX380-Trainer - Tasks${NC}
  1  Node Taints entfernen + Deployment      (Pod Scheduling)
  2  LDAP als Identity Provider              (Authentication)
  3  CSR signieren, Gruppe, kubeconfig       (Security / API-Zugriff)
  4  OADP Restore + SCC-Fix (anyuid/SA)      (Backup/Restore + SCC)
  5  Log Forwarding Syslog + EventRouter     (Logging Vector)
  6  GitOps Operator, Route, RBAC, PKI       (ArgoCD/GitOps)
  7  MachineConfig via ArgoCD (motd)         (GitOps + Machine Mgmt)

  Beispiele:
    ./ex380-trainer.sh task 3     # nur Aufgabentext anzeigen
    ./ex380-trainer.sh setup 1
    ./ex380-trainer.sh grade 1
    FORCE=1 ./ex380-trainer.sh setup 5    # destruktiver Reset
    ./ex380-trainer.sh grade all
EOF
}

main() {
  local cmd="${1:-}" arg="${2:-}"
  case "$cmd" in
    list|"") list_tasks ;;
    task)
      case "$arg" in
        1|2|3|4|5|6|7) "task_${arg}_text" ;;
        *) echo "Usage: $0 task <1-7>" >&2; exit 2 ;;
      esac
      ;;
    setup)
      need_login
      case "$arg" in
        1|2|3|4|5|6|7) "setup_$arg" ;;
        *) echo "Usage: $0 setup <1-7>" >&2; exit 2 ;;
      esac
      ;;
    grade)
      need_login
      case "$arg" in
        1|2|3|4|5|6|7) "grade_$arg"; summary ;;
        all)
          local i
          for i in 1 2 3 4 5 6 7; do "grade_$i"; done
          summary
          ;;
        *) echo "Usage: $0 grade <1-7|all>" >&2; exit 2 ;;
      esac
      ;;
    *) list_tasks; exit 2 ;;
  esac
}

main "$@"
