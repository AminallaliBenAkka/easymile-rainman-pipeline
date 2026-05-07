# easymile-rainman-pipeline
Automated LiDAR aging and weather impact characterization pipeline (ROS/Python) for predictive maintenance on autonomous vehicles.

# Rainman LiDAR Pipeline : Maintenance Prédictive

## Description
Ce projet contient le pipeline d'acquisition automatisé et d'analyse algorithmique développé au sein d'**EasyMile** pour caractériser le vieillissement des capteurs LiDAR en conditions réelles d'exploitation. 

L'objectif est d'étudier l'impact de l'usure mécanique et des conditions météorologiques (pluie, diffusion de Mie) sur la perception 3D, afin d'initier une stratégie de **maintenance prédictive** pour les véhicules autonomes (architecture Gen3).

## Architecture du Projet

Le dépôt est structuré de la manière suivante :

```text
📦 easymile-rainman-pipeline
 ┣ 📂 analysis/                 # Scripts d'analyse algorithmique (Python/ROS)
 ┃ ┣ 📜 ads_searchbox_process.py  # Extraction des métriques (P95, Bruit, ROS Transform)
 ┃ ┗ 📜 ads_searchbox_plot.py     # Génération des graphiques d'analyse
 ┣ 📂 config/                   # Fichiers de configuration
 ┃ ┗ 📜 targets.yaml              # Paramétrage des cibles ISO-3691-4 (coordonnées)
 ┣ 📂 logs/                     # Fichiers de journalisation et données météo
 ┃ ┣ 📜 ADS_20260419_230000.json  # Exemple de fichier météo généré par l'API
 ┃ ┗ 📜 ads-record.log            # Logs d'exécution système
 ┣ 📂 results/                  # Résultats des traitements
 ┃ ┗ 📜 searchbox_metrics.csv     # Base de données longitudinale des métriques LiDAR
 ┣ 📜 ads_record_once.sh        # Script Bash d'acquisition (ROS bag & Météo)
 ┣ 📜 ads-record.service        # Service Systemd pour l'exécution en arrière-plan
 ┗ 📜 ads-record.timer          # Timer Systemd pour l'automatisation bi-quotidienne
```
# Fonctionnement du Pipeline

Le système repose sur deux piliers principaux :

1. Acquisition Automatisée (Linux / Bash)
L'acquisition des données (nuages de points ROS et conditions météorologiques via API) est 100 % autonome. Elle est gérée par les utilitaires Linux systemd :

- ads-record.timer déclenche les enregistrements de manière bi-quotidienne.
- ads-record.service lance le script racine.
- ads_record_once.sh exécute la capture du .bag ROS et génère le fichier .json contenant la météo du moment.

2. Traitement Algorithmique (Python / ROS)
Les scripts contenus dans le dossier analysis/ filtrent les nuages de points dans des zones d'intérêt (Searchboxes) définies dans targets.yaml.

- Correction géométrique : Application de matrices mathématiques (ROS Transform) pour compenser l'excentricité des capteurs.
- Extraction : Calcul de la portée effective (Percentile 95) et du bruit de mesure (Écart-type spatial sigma).
- Les résultats sont compilés dans searchbox_metrics.csv pour alimenter les futurs Dashboards d'alerte.

# Installation & Déploiement
Prérequis

- Ubuntu / Linux
- ROS (Robot Operating System)
- Python 3.x avec les bibliothèques d'analyse (pandas, numpy, matplotlib, rospy)

Activer l'automatisation Systemd
Pour déployer la tâche automatisée sur une station (ex: plateforme Rainman) :

sudo cp ads-record.service /etc/systemd/system/
sudo cp ads-record.timer /etc/systemd/system/
sudo systemctl enable ads-record.timer
sudo systemctl start ads-record.timer

Lancer l'analyse manuellement
Pour générer le fichier CSV à partir des données acquises :

python3 analysis/ads_searchbox_process.py --config config/targets.yaml

# Auteur & Contexte
- Auteur : Amin ALLALI BEN AKKA
- Tuteur Industriel : Antonin DEVILLE
