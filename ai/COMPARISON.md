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
| B (capteurs embarqués) | `autoresearch/tier-b-aug31` | `f612ae0` | Raycasts "moustaches" + frein de virage + sondes latérales de recentrage + proprioception — aucun accès à la courbe | headless, `--repeats=3` | **0.230213** (tuning suspendu, point dur identifié) | 0.433388 | oui, directement (même harnais) |
| C Phase 1 (vision offline) | `autoresearch/tier-c-aug31` | `58ee972` | Image caméra embarquée (320×180, redimensionnée à 64×36) | entraînement externe (PyTorch), métrique d'erreur de prédiction hors-ligne | N/A (pas un score de course) — MAE steering 0.083 rad, MAE engine_force 11.96 | — | **non** — proxy explicitement non comparable |
| C Phase 2 (vision closed-loop) | — | — | Image caméra embarquée | non-headless, `ai/vision/run_eval_vision.gd` (à construire) | différé | — | oui, une fois construit |

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
  - **Tuning suspendu ici** (choix utilisateur) : `0.230213`, ×5.6 par
    rapport au premier candidat Tier B, **toujours net en dessous de
    Tier A (0.371)**. Point dur restant clairement identifié pour une
    reprise future : le tunnel + épingle serrée vers 84-106m bloque
    `trailer_truck` de façon quasi-systématique ; une correction efficace
    demanderait probablement un signal plus riche que ceux actuellement
    disponibles (ex. distinguer "route qui rétrécit progressivement" d'un
    "tunnel bas/étroit" via la sonde verticale, ou une détection de
    contact/collision latérale plus directe) plutôt qu'un réglage de
    vitesse global.
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
- **Tier C Phase 2** (boucle fermée réelle, but d'obtenir un
  `aggregate_score` comparable) est délibérément différée à un futur go
  explicite (nouvelle infra : pont d'inférence Godot↔Python, eval
  non-headless).
