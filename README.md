EX280 Trainer
Self-contained Übungs- und Validierungsumgebung für die 23 EX280-Tasks. Reine Bash-Skripte, gebaut fürs ROL-Lab-Terminal. Kein Framework, nur oc, bash, python3 (für JSON-Parsing) und für Task 17 helm.

Schnellstart
cd ex280-trainer
chmod +x ex280 tasks/*.sh        # einmalig
oc login ...                      # an deinem ROL-Cluster anmelden

./ex280 list                      # Übersicht
./ex280 setup 5                   # Ausgangslage für Task 5 herstellen
# ... Task in der Konsole/CLI lösen ...
./ex280 validate 5                # Scorecard
Workflow pro Task
./ex280 setup N legt Projekte/Deployments an und druckt das Ziel.
Du löst die Aufgabe (CLI oder Web-Console) — wie in der echten Prüfung.
./ex280 validate N prüft objektiv per oc und zeigt ✔/x pro Kriterium.
Gesamtbewertung
./ex280 setup all       # alles vorbereiten (dauert etwas)
./ex280 grade           # kompakter Gesamtscore über alle 23 Tasks
Aufräumen
./ex280 clean           # löscht alle Trainings-Namespaces
Cluster-weite Änderungen (HTPasswd-IdP, cluster-admin-Bindungen, project-request-Template, kubeadmin-Secret) setzt clean NICHT zurück — das ist im ROL-Lab nach Reset ohnehin frisch.

Hinweise zu einzelnen Tasks
1/2 (IdP/RBAC): User existieren als Identity erst nach erstem Login. Die RBAC-Checks nutzen oc auth can-i --as=<user> und funktionieren auch ohne Login.
13 (MySQL): Setup erzeugt absichtlich einen CrashLoop. Reparieren, nicht neu anlegen.
15 (TLS-Route): Validator prüft edge-Termination + Cert/Key im Route-Objekt.
16 (Operator): CSV-Phase „Succeeded“ kann nach Subscription etwas dauern — ggf. erneut prüfen.
17 (Helm): Default-Namespace bluebook; abweichend via EX280_HELM_NS=... ./ex280 validate 17.
18 (must-gather): Upload selbst ist nicht prüfbar; der Validator prüft das Tar-Artefakt im $HOME.
20/22: Setzt voraus, dass die NFS-StorageClass im Lab vorhanden ist; Labels fürs NetworkPolicy- Szenario werden im Setup gesetzt.
Struktur
ex280-trainer/
├── ex280                 # Runner
├── lib/common.sh         # Scorecard + oc-Helfer
├── tasks/NN_setup.sh     # Ausgangslage
└── tasks/NN_validate.sh  # Prüfung
