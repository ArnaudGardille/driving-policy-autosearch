# Comparaison des niveaux de perception (Tier A / B / C)

Comparaison des performances atteignables par la politique de conduite IA
selon le niveau d'information disponible, sur le même harnais de score
(`aggregate_score` = minimum des scores des 3 véhicules — `car_base`,
`trailer_truck`, `tow_truck` — via `tests/run_eval.gd` /
`tests/ai_benchmark.gd` / `race/race_manager.gd:compute_score()`).

## Caveat de non-déterminisme (important pour lire ce tableau)

Jolt Physics (moteur physique du projet) utilise un solveur multi-threadé
qui n'est pas parfaitement reproductible d'un run à l'autre — voir
`PROGRAM.md`, section "Determinism caveat". Un même commit peut produire des
scores différents selon l'ordre de résolution des contacts. **Tout score
cité ici doit avoir été mesuré avec `--repeats=3` (ou plus) sur
`tests/run_eval.gd`, en retenant le pire des runs** — un score à run unique
n'est pas une preuve suffisante, en particulier pour un véhicule qui frôle
une marge étroite (typiquement `tow_truck`).

## Tableau

| Tier | Branche | Commit | Sensing | Mode d'éval | `aggregate_score` | `mean_score` | Comparable à A ? |
|---|---|---|---|---|---|---|---|
| A (référence) | `autoresearch/aug31` | `279ba58` | Courbe `Path3D` exacte (privilégié — plus précis que ce qu'un humain voit à l'écran) | headless, `--repeats=3` | **0.370715** | 0.959897 | référence |
| B (capteurs embarqués, aug31) | `autoresearch/tier-b-aug31` | `f612ae0` | Raycasts "moustaches" + frein de virage + sondes latérales de recentrage + proprioception — aucun accès à la courbe | headless, `--repeats=3` | 0.230213 (tuning suspendu, point dur identifié) | 0.433388 | oui, directement (même harnais) |
| B (capteurs embarqués, sep1) | `autoresearch/tier-b-sep1` | `b5dfcd4` | Idem + lissage de direction spécifique remorque + frein de sécurité par vitesse de lacet spécifique véhicules-à-remorque — aucun accès à la courbe | headless, `--repeats=3` | **0.779241** | 0.804731 | **oui, et dépasse A** (×2.1 par rapport à A) |
| C Phase 1 (vision offline) | `autoresearch/tier-c-aug31` | `58ee972` | Image caméra embarquée (320×180, redimensionnée à 64×36) | entraînement externe (PyTorch), métrique d'erreur de prédiction hors-ligne | N/A (pas un score de course) — Phase 1 initiale (2026-08-31, mono-expert Tier A, 316 frames / 3 runs) : MAE steering 0.083 rad, MAE engine_force 11.96. Mise à jour 2026-09-01 (974 frames / 14 runs, mix Tier A + Tier B — voir notes, **non comparable en apples-to-apples** à la ligne du dessus) : MAE steering 0.076 rad, MAE engine_force 13.60 | — | **non** — proxy explicitement non comparable |
| C Phase 2 (vision closed-loop) | `autoresearch/tier-c-phase2` | `81b8150` | Image caméra embarquée, boucle fermée réelle | non-headless, `ai/vision/run_eval_vision.gd`, `--repeats=3` | **0.100781** | 0.129766 | oui, même harnais |

## Notes

- **Tier A** : `0.370715` est le pire des 3 répétitions sur le commit
  `279ba58` (`ai_drive_task.gd` non modifié) — remplace le `1.160353`
  précédemment rapporté, qui s'est révélé être un run chanceux isolé (voir
  `results.tsv` et le caveat ci-dessus). `car_base` et `trailer_truck`
  finissent de façon fiable (1.348, 1.161) ; `tow_truck` est le goulot
  d'étranglement et le seul véhicule dont le score varie selon le run
  (0.377 / 0.442 / 0.371 sur 3 répétitions).
- **Tier B** : brancher depuis `279ba58` (pas depuis un commit `try:` non
  encore évalué), pour partir d'une base connue et stable.
  **Historique de tuning** :
  - `575c49f` (baseline, 0.041296) : les 3 véhicules sortent de la route
    de façon quasi identique après ~15-20m. Diagnostic initial : la
    chaussée physique (maillage CSG) est plus étroite (demi-largeur
    réelle ~1.85-2m) que la tolérance de score `TRACK_WIDTH=4.0` — la
    voiture quitte donc la chaussée physique bien avant que le système de
    score ne le détecte, et les moustaches (qui ne scannent que vers
    l'avant) ne retrouvent alors plus de signal exploitable.
  - `9a08826` (0.230213, **×5.6**) : l'ajout des sondes latérales seul
    (sans corriger le bug ci-dessous) n'avait quasiment rien changé
    (0.0413), ce qui a mené à investiguer plus profondément via une
    télémétrie `debug_events` temporaire. **Vrai bug trouvé** : la
    sémantique des moustaches est "distance courte = chaussée confirmée
    à proximité, distance longue/`max_range` = rien trouvé (bord ou
    vide)" — documentée correctement dans `ai/onboard_sensing.gd`, mais
    la logique de conduite dans `ai_drive_task.gd` l'interprétait à
    l'envers : elle dirigeait la voiture vers la lecture la PLUS LONGUE
    en pensant que ça signifiait "route dégagée", alors que ça signifiait
    "hors piste". La voiture se dirigeait donc activement vers le vide
    dès le premier tick. Correction : pondération par `(max_range -
    distance)` au lieu de `distance`, inversion du signe de la
    correction des sondes latérales, inversion du seuil du frein de
    sécurité, et suppression du freinage basé sur les moustaches avant
    (peu informatif sur cette route étroite — presque toujours proche de
    sa distance courte déterminée par l'angle de tir, quelle que soit la
    courbure à venir). `car_base` atteint désormais 291.6m de façon
    stable (sur ~366m de piste) ; `tow_truck`/`trailer_truck` progressent
    aussi nettement mais restent plus instables entre répétitions
    (`time_up` vs `fell_off` selon le run).
  - `f612ae0` (0.230213, agrégat inchangé mais `tow_truck` amélioré) :
    capture d'écran (`tests/capture_run.gd`) montrant `trailer_truck` se
    renverser dans une épingle très serrée juste après un tunnel étroit
    (~97-106m) — trop de vitesse à l'approche. Les moustaches avant
    contiennent en fait un signal de courbure exploitable (leur poids
    total de confirmation baisse quand la route s'éloigne fortement de
    l'axe droit), réutilisé pour freiner proportionnellement. `tow_truck`
    passe régulièrement ce point désormais (0.275 → 0.355/0.358 sur 2
    répétitions sur 3). `trailer_truck` reste identique bit pour bit au
    run précédent sur sa pire répétition — son blocage est **ailleurs et
    plus précoce** (~84m, dans le tunnel lui-même, probablement un
    problème d'alignement/largeur physique plutôt que de vitesse en
    virage).
  - **Piste explorée et abandonnée** : ralentir spécifiquement à cet
    endroit (`min_speed` 5.0→2.5, seuil de frein 0.85→0.95) résout le
    blocage de `trailer_truck` seul (84m → 114-354m) mais casse `car_base`
    (291m → 86m) et dégrade `tow_truck` une fois appliqué aux 3 véhicules
    avec le même jeu de réglages partagé — la politique n'a pas de moyen
    de savoir "je suis dans LE tunnel" sans tricher avec la position sur
    la courbe, donc un réglage global ne peut pas cibler ce seul endroit.
  - **Tuning suspendu à `0.230213`** (choix utilisateur, fin de session
    aug31), ×5.6 par rapport au premier candidat Tier B, **toujours net en
    dessous de Tier A (0.371)**. Point dur restant clairement identifié
    pour une reprise future : le tunnel + épingle serrée vers 84-106m
    bloque `trailer_truck` de façon quasi-systématique ; une correction
    efficace demanderait probablement un signal plus riche que ceux
    actuellement disponibles (ex. distinguer "route qui rétrécit
    progressivement" d'un "tunnel bas/étroit" via la sonde verticale, ou
    une détection de contact/collision latérale plus directe) plutôt qu'un
    réglage de vitesse global.
  - **Reprise sep1** (branche `autoresearch/tier-b-sep1`, boucle
    `autoresearch` façon `PROGRAM.md`, ~19 expériences journalisées dans
    `results.tsv` : 1 crash, 15 discard, 3 keep) — identification du point
    dur : le "tunnel" est en fait un `HugeTire` (`TorusMesh`,
    `inner_radius=3.5`) que la piste traverse via un pont étroit, juste
    avant l'épingle. Diagnostic visuel (`tests/capture_run.gd`,
    `runs/diag_trailer_capture/` et `runs/diag_tow_capture/`, technique
    recommandée par `PROGRAM.md` après plusieurs échecs sans signal clair)
    :
    - `trailer_truck` : l'échec au point dur est une CHUTE EN Y
      (`fell_off` = passage sous la surface de la piste, PAS un
      dépassement latéral — `race_manager.gd:_end_race`), cohérent avec la
      remorque tractée (jointure rigide `Generic6DOFJoint3D`) qui part
      large dans l'épingle et tombe du bord d'un pont étroit — invisible
      aux capteurs montés sur le véhicule TRACTEUR. Plusieurs tentatives
      de ralentissement global (`min_speed` réduit spécifiquement pour les
      véhicules à remorque, via un signal gratuit déjà calculé chaque
      tick — `OnboardSensing.collect_body_rids(car).size()` distingue
      `car_base`=1 corps, `trailer_truck`=2, `tow_truck`=7, donc "ce
      véhicule tracte-t-il quelque chose" sans lire la courbe ni l'état de
      course) ont amélioré le meilleur cas mais restaient à haute variance
      (`results.tsv` 786fc0a/e1cc363/afa09d0 — pire répétition ~0.22-0.23,
      pas d'amélioration nette). **Le vrai correctif** (`e657f71`, gardé) :
      lisser la commande de direction (filtre passe-bas, `smoothing=0.3`)
      spécifiquement pour ce véhicule — la remorque semble balancée large
      par des changements de direction saccadés (recalculés à chaque tick
      à partir de capteurs bruités), pas seulement par la vitesse.
      `trailer_truck` passe de systématiquement écrasé (~84-112m) à
      **gagnant les 3 répétitions** (1.084/1.079/1.074).
    - `tow_truck` : point dur similaire en position (même zone du
      `HugeTire`) mais mécanisme DIFFÉRENT — capture visuelle
      (`runs/diag_tow_capture/012_t24s.png`) montre le véhicule tourné
      d'environ 90° en travers du pont étroit, coincé — un véritable
      tête-à-queue (spin-out), pas juste un blocage vers l'avant. Cinq
      mécanismes de récupération testés et rejetés avant d'obtenir cette
      image (échelle `min_speed`, lissage de direction élargi à
      `tow_truck`, direction de récupération fixée, boost de
      marche-arrière combiné, marge de sécurité de bord renforcée —
      `results.tsv` 786fc0a/ee879c5/2f5adf8/49d16a9/e08c8f0 — tous
      ciblaient un blocage vers l'avant, pas une rotation). **Le vrai
      correctif** (`965ad5f`, puis affiné en `b5dfcd4`, gardé) : filet de
      sécurité par vitesse de lacet (`car.angular_velocity.y`, propriété
      physique du véhicule déjà utilisée pour `linear_velocity` — pas un
      accès à la courbe) — si `|yaw_rate| > seuil`, freiner fort vers
      `min_speed * 0.5`. Tier A avait déjà essayé un filet similaire
      (seuil 1.2 rad/s) et l'avait abandonné car mal calibré (un virage
      normal y produit déjà ~2 rad/s) ; balayage empirique propre à ce
      tier (0.5 à 3.0 rad/s testés) montre que `0.5` est le seuil qui
      s'active utilement ici — la politique de direction par moustaches de
      ce tier ne produit apparemment pas les mêmes vitesses de lacet en
      virage normal que la politique de Tier A. Version globale
      (`965ad5f`) : corrige `tow_truck` (0.275→0.779) et améliore encore
      `trailer_truck` (→0.840) mais RÉGRESSE `car_base` (0.795→0.374, sans
      remorque, faux déclenchement) qui devient le nouveau goulot
      d'étranglement — agrégat 0.374372, déjà au-dessus de Tier A. Version
      affinée (`b5dfcd4`, gardée) : filet de lacet limité aux véhicules à
      remorque (même signal `collect_body_rids().size()>1` que pour le
      lissage de direction) — `car_base` retourne exactement à son
      comportement d'origine (0.795, bit pour bit sur les 3 répétitions),
      `tow_truck`/`trailer_truck` gardent leurs gains complets.
  - **Score final de cette reprise** : `0.779241` (agrégat, pire de 3
    répétitions, commit `b5dfcd4`), mean `0.804731` — **×3.4 par rapport
    au point de départ de cette reprise (0.230213), ×2.1 par rapport à la
    référence Tier A (0.370715)**. Goulot d'étranglement restant :
    `tow_truck` (0.779, toujours le plus bas des 3, mais ne tombe/coince
    plus — la pire répétition observée finit `time_up` à 285-354m sur
    ~366m, donc un problème de rythme/temps plus qu'un échec dur).
    Tentative de relâcher le frein de lacet (`yaw_brake_speed_scale`
    0.5→0.7, sur l'hypothèse que la marge de sécurité pouvait être
    échangée contre de la vitesse) : réintroduit une instabilité réelle
    dans une répétition sur trois (`results.tsv` d8e69e6) — `0.5` est une
    valeur bien calibrée, pas un choix arbitraire avec de la marge.
    Piste non explorée pour une reprise future : le point dur restant
    n'est plus un blocage physique dur mais un déficit de rythme — un
    réglage de vitesse de croisière plus fin (spécifique aux véhicules à
    remorque, même famille de signal que ci-dessus) pourrait grappiller
    les dernières secondes sans revenir à l'instabilité du lacet.
- **Tier C Phase 1** (2026-08-31) : pipeline complet validé de bout en
  bout — capture (`ai/vision/record_dataset.gd`, caméra montée à
  l'exécution) → 3 runs démonstrateurs Tier A (`car_base`: 82 paires,
  gagné ; `trailer_truck`: 107 paires, gagné ; `tow_truck`: 127 paires,
  time_up) → 316 images au total, 234 en train / 82 en val (découpage par
  run entier, pas par frame, pour éviter la fuite entre frames
  temporellement adjacentes) → petit CNN (28 642 paramètres,
  `truck-town-vision-training/train.py`) entraîné 120s sur la RTX 3090.
  **Résultat (jeu de données minimal, à but de validation du pipeline,
  pas encore représentatif)** : MAE steering = 0.083 rad (~21% de la
  plage `±0.4`), MAE engine_force = 11.96 (~12% de la plage `±100`).
  Checkpoint sauvegardé (`checkpoints/vision_policy.pt`). Rappel : ceci
  reste un proxy hors-ligne, pas un score de course — ne donne aucune
  indication directe sur le comportement en boucle fermée. Prochaine
  étape naturelle avant la Phase 2 : capturer davantage de runs
  (plusieurs par véhicule, y compris des runs Tier A où le point de
  chute varie, cf. le caveat de non-déterminisme) pour un jeu de données
  moins minimal.
- **Tier C Phase 1 — mise à jour dataset élargi (2026-09-01)** : suite à la
  note ci-dessus, un script de capture détaché a tourné en tâche de fond
  pour ajouter 12 runs (`car_base_run2/3/4/5`, `trailer_truck_run2/3/4/5`,
  `tow_truck_run2/3/4/5`) aux 3 runs déjà présents
  (`car_base_run1`, `trailer_truck_run1`, `tow_truck_run1`) — 15 runs
  tentés, 14 indexés avec succès (`trailer_truck_run3` a planté en cours
  de capture côté Godot — `WARNING: 2 ObjectDB instances were leaked at
  exit` — sans écrire de `manifest.json` ; `prepare.py` n'indexe que les
  répertoires avec `manifest.json` présent, donc ce run est exclu
  automatiquement, aucune action manuelle nécessaire).
  **Découverte importante en cours de route** : `ai/ai_drive_task.gd` sur
  cette branche (et donc sur `master`, dont elle part) est actuellement
  la politique **Tier B** (capteurs "moustaches"), pas la politique
  Tier A (courbe exacte) qui avait servi à capturer le dataset Phase 1
  initial. Autrement dit **le dataset résultant est un mélange
  Tier A + Tier B**, pas "le même expert, plus de données" :
  - `car_base` : `_run1` (82 paires, score 1.348 — Tier A, cohérent avec
    le score `car_base` de la ligne Tier A du tableau) ; `_run2` à
    `_run5` (79 paires chacun, score identique 0.795 — Tier B).
  - `trailer_truck` : `_run1` (107 paires, score 1.161 — Tier A, gagné,
    cohérent avec le `trailer_truck` de la ligne Tier A) ; `_run2`,
    `_run4`, `_run5` (42 paires chacun, score identique 0.303 — Tier B,
    cohérent avec la difficulté connue de `trailer_truck` sur ce niveau
    documentée dans la section Tier B ci-dessus) ; `_run3` planté (voir
    ci-dessus).
  - `tow_truck` : `_run1` (127 paires, score 0.433 — Tier A, `time_up`) ;
    `_run2` à `_run5` (54 paires chacun, score identique 0.218 —
    Tier B).
  - Les scores Tier B sont identiques d'un run à l'autre pour un même
    véhicule (contrairement au caveat de non-déterminisme évoqué plus
    haut pour Tier A) — la politique de capteurs n'introduit
    apparemment pas de variance perceptible d'un run à l'autre sur ce
    parcours, à la différence du solveur physique multi-threadé seul.
  - **Ce mélange est gardé intentionnellement, pas filtré** : une piste
    discutée (hors périmètre de cette mise à jour, pas implémentée ici)
    consiste à mélanger délibérément plusieurs tiers de politique comme
    démonstrateurs — y compris les échecs — pour obtenir de la diversité
    de retour (`return diversity`) en vue d'une approche type
    Decision-Transformer. Un dataset de qualité mixte est donc une
    caractéristique voulue ici, pas du bruit à retirer avant
    l'entraînement.
  - **Nouveau total** : 974 images (788 train / 186 val, découpage par
    run entier, seed=0) sur 14 runs. `TIME_BUDGET` remonté de 120s à
    400s dans `prepare.py` (proportionnellement à ~3x plus de frames /
    ~4.7x plus de runs, la RTX 3090 ayant largement la marge) —
    `train.py` inchangé sinon.
  - **Résultat** : MAE steering = 0.076 rad (contre 0.083 rad avant,
    ~8% mieux), MAE engine_force = 13.60 (contre 11.96 avant, ~14%
    moins bien).
  - **Lecture honnête, sans trancher artificiellement** : ce n'est **pas**
    une comparaison apples-to-apples avec le résultat Phase 1 initial —
    l'ancienne baseline (0.083 / 11.96) vient d'un dataset mono-expert
    Tier A (316 frames, 3 runs), la nouvelle vient d'un dataset
    mixte Tier A + Tier B (974 frames, 14 runs) qui inclut
    délibérément des démonstrations de niveau plus faible (y compris un
    run raté). Une MAE plus mauvaise ici ne veut donc pas forcément dire
    "plus de données a nui" — ça peut aussi vouloir dire "le dataset
    contient maintenant des exemples volontairement plus durs/moins
    experts". Concrètement : le MAE steering s'améliore légèrement,
    le MAE engine_force se dégrade légèrement — résultat **mitigé /
    peu concluant**, pas un verdict net dans un sens ou dans l'autre.
    Pas de sur-interprétation à en tirer côté "plus de données aide" ou
    "plus de données nuit" : les deux facteurs (volume de données,
    mélange de tiers) ont changé en même temps, donc cette expérience
    seule ne permet pas de les démêler. Une expérience future
    apples-to-apples nécessiterait soit un dataset élargi mais
    mono-tier, soit un conditionnement explicite du modèle sur le tier
    du démonstrateur.
- **Tier C Phase 2** (2026-09-02) : boucle fermée construite et validée —
  pont TCP `ai/vision/vision_inference_client.gd` ↔
  `truck-town-vision-training/infer_server.py` (charge
  `checkpoints/vision_policy.pt`, le modèle entraîné sur le dataset mixte
  974 frames de la note ci-dessus), politique `ai/vision/vision_drive_task.gd`
  (BTAction comme A/B, décision toutes les 0.1s, dernière action maintenue
  entre deux inférences), driver d'éval non-headless
  `ai/vision/run_eval_vision.gd` (même contrat JSON que `run_eval.gd`).
  Premier résultat réel, 3 véhicules, 65s, run unique (pas de `--repeats` —
  coût temps réel ~65s/véhicule, contrairement à l'éval headless A/B) :
  `aggregate_score` = 0.124124 (`mean_score` = 0.144328), `fair=true`
  et `ok=true` sur les 3 véhicules. Détail : `car_base` 0.1241 (45.5m),
  `tow_truck` 0.1399 (51.3m), `trailer_truck` 0.1690 (61.9m) — tous
  `fell_off`. **Confirmé avec `--repeats=3`** (même code, `81b8150`) :
  **`aggregate_score` = 0.100781** (`mean_score` = 0.129766, pire des 3
  répétitions par véhicule) — `car_base` 0.1008 (répétitions 0.1008 /
  0.1220 / 0.1578), `tow_truck` 0.1347 (0.1428 / 0.1347 / 0.1475),
  `trailer_truck` 0.1538 (0.1854 / 0.2157 / 0.1538), tous `fair=true`.
  Cohérent avec le run unique (même ordre de grandeur, pas de renversement
  de conclusion) — c'est le chiffre à citer désormais. Net : nettement en
  dessous de Tier A (0.371) et Tier B
  (0.230–0.779 selon session), attendu pour une première politique de
  behavior cloning pur sans itération — signature typique de l'erreur
  cumulative (compounding error) documentée par Ross et al., *DAgger*
  (2011) : le modèle n'a jamais vu, pendant l'entraînement, comment se
  rattraper depuis un état légèrement décalé de la trajectoire experte,
  donc la moindre dérive s'auto-amplifie. Prochaine étape naturelle si on
  veut améliorer ce chiffre : itération à la DAgger (faire rouler cette
  politique, capturer les états visités, les relabelliser avec l'action de
  l'expert de référence — recalculable hors-ligne puisque la pose exacte
  en simulation est connue — réinjecter dans le dataset, réentraîner)
  plutôt qu'un changement d'architecture. **Non comparable en
  apples-to-apples au dataset mixte Tier A+B ci-dessus** pour la partie
  provenance du dataset — le score de Phase 2 mesure la politique
  actuellement entraînée dessus, pas un tier de démonstrateur isolé.
