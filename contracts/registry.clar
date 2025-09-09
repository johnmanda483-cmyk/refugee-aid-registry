;; title: Refugee Aid Registry
;; version: 1.0.0
;; summary: Verified access to food and shelter for refugees
;; description: A simple, privacy-aware registry that records refugee profiles,
;;              verifier approvals, and grants for food and shelter assistance.

;; =============================================================================
;; ERROR CONSTANTS
;; =============================================================================
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-INPUT (err u103))
(define-constant ERR-PAUSED (err u104))

;; =============================================================================
;; SYSTEM CONSTANTS
;; =============================================================================
(define-constant MAX-NAME-LEN u48)
(define-constant MAX-NOTE-LEN u120)
(define-constant MAX-ORIGIN-LEN u40)
(define-constant MAX-NEEDS-LEN u80)

;; Service types
(define-constant SERVICE-FOOD u1)
(define-constant SERVICE-SHELTER u2)

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================
(define-data-var contract-owner principal tx-sender)
(define-data-var system-paused bool false)
(define-data-var next-service-id uint u1)

;; =============================================================================
;; DATA MAPS
;; =============================================================================

;; Whitelisted verifiers (NGOs, agencies)
(define-map verifiers principal bool)

;; Refugee profiles by principal
(define-map refugees principal {
  identity-hash: (string-ascii 66),  ;; hex-encoded hash string
  family-size: uint,
  country-of-origin: (string-ascii 40),
  special-needs: (optional (string-ascii 80)),
  verified: bool,
  verification-level: uint,
  created-at: uint,
  updated-at: uint,
  verification-note: (optional (string-ascii 120))
})

;; Granted services by monotonically increasing service id
(define-map services uint {
  refugee: principal,
  service-type: uint,          ;; u1 food, u2 shelter
  duration-days: uint,         ;; requested/approved duration
  granted-by: principal,       ;; verifier or owner
  granted-at: uint,
  note: (optional (string-ascii 120))
})

;; Index of services granted to a refugee (stores up to 50 service ids)
(define-map refugee-services principal (list 50 uint))

;; =============================================================================
;; PRIVATE HELPERS
;; =============================================================================

(define-private (is-owner (who principal)) (is-eq who (var-get contract-owner)))

(define-private (require-not-paused)
  (if (var-get system-paused)
    ERR-PAUSED
    (ok true)
  ))

(define-private (now) stacks-block-height)

;; Safely append a uint to a bounded list of uints (len <= max)
(define-private (append-u (xs (list 50 uint)) (x uint))
  (unwrap-panic (as-max-len? (append xs x) u50)))

;; =============================================================================
;; READ-ONLY FUNCTIONS
;; =============================================================================

(define-read-only (get-owner) (var-get contract-owner))

(define-read-only (is-verifier (who principal))
  (default-to false (map-get? verifiers who)))

(define-read-only (get-system-status)
  { paused: (var-get system-paused), next-service-id: (var-get next-service-id) })

(define-read-only (get-refugee (who principal))
  (map-get? refugees who))

(define-read-only (get-refugee-services (who principal))
  (default-to (list) (map-get? refugee-services who)))

(define-read-only (get-service (sid uint))
  (map-get? services sid))

;; =============================================================================
;; ADMIN FUNCTIONS (OWNER)
;; =============================================================================

(define-public (add-verifier (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (map-set verifiers who true)
    (ok true)
  ))

(define-public (remove-verifier (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (map-set verifiers who false)
    (ok true)
  ))

(define-public (pause-system)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set system-paused true)
    (ok true)
  ))

(define-public (resume-system)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set system-paused false)
    (ok true)
  ))

;; =============================================================================
;; REGISTRY FUNCTIONS
;; =============================================================================

(define-public (register-refugee
  (identity-hash (string-ascii 66))
  (family-size uint)
  (country (string-ascii 40))
  (special (optional (string-ascii 80)))
)
  (let (
    (existing (map-get? refugees tx-sender))
  )
    (try! (require-not-paused))
    (asserts! (> family-size u0) ERR-INVALID-INPUT)
    (asserts! (is-none existing) ERR-ALREADY-EXISTS)

    (map-set refugees tx-sender {
      identity-hash: identity-hash,
      family-size: family-size,
      country-of-origin: country,
      special-needs: special,
      verified: false,
      verification-level: u0,
      created-at: (now),
      updated-at: (now),
      verification-note: none
    })

    (ok true)
  ))

(define-public (update-profile
  (family-size uint)
  (country (string-ascii 40))
  (special (optional (string-ascii 80)))
)
  (let ((profile (unwrap! (map-get? refugees tx-sender) ERR-NOT-FOUND)))
    (try! (require-not-paused))
    (asserts! (> family-size u0) ERR-INVALID-INPUT)

    (map-set refugees tx-sender (merge profile {
      family-size: family-size,
      country-of-origin: country,
      special-needs: special,
      updated-at: (now)
    }))
    (ok true)
  ))

;; Verifier or owner can verify a refugee and set a level (e.g., 1..3)
(define-public (verify-refugee
  (who principal)
  (level uint)
  (note (optional (string-ascii 120)))
)
  (let ((profile (unwrap! (map-get? refugees who) ERR-NOT-FOUND)))
    (try! (require-not-paused))
    (asserts! (or (is-owner tx-sender) (default-to false (map-get? verifiers tx-sender))) ERR-UNAUTHORIZED)

    (map-set refugees who (merge profile {
      verified: true,
      verification-level: level,
      verification-note: note,
      updated-at: (now)
    }))
    (ok true)
  ))

;; =============================================================================
;; SERVICE GRANTS (FOOD / SHELTER)
;; =============================================================================

(define-public (grant-service
  (who principal)
  (service-type uint)
  (duration-days uint)
  (note (optional (string-ascii 120)))
)
  (let (
    (profile (unwrap! (map-get? refugees who) ERR-NOT-FOUND))
    (sid (var-get next-service-id))
    (idx (default-to (list) (map-get? refugee-services who)))
  )
    (try! (require-not-paused))
    (asserts! (or (is-owner tx-sender) (default-to false (map-get? verifiers tx-sender))) ERR-UNAUTHORIZED)
    (asserts! (get verified profile) ERR-UNAUTHORIZED)
    (asserts! (> duration-days u0) ERR-INVALID-INPUT)
    (asserts! (or (is-eq service-type SERVICE-FOOD) (is-eq service-type SERVICE-SHELTER)) ERR-INVALID-INPUT)
    (asserts! (< (len idx) u50) ERR-INVALID-INPUT)

    (map-set services sid {
      refugee: who,
      service-type: service-type,
      duration-days: duration-days,
      granted-by: tx-sender,
      granted-at: (now),
      note: note
    })

    (map-set refugee-services who (append-u idx sid))
    (var-set next-service-id (+ sid u1))
    (ok sid)
  ))

;; Convenience wrappers
(define-public (grant-food (who principal) (days uint) (note (optional (string-ascii 120))))
  (grant-service who SERVICE-FOOD days note))

(define-public (grant-shelter (who principal) (days uint) (note (optional (string-ascii 120))))
  (grant-service who SERVICE-SHELTER days note))

;; =============================================================================
;; LIGHTWEIGHT QUERIES
;; =============================================================================

(define-read-only (is-registered (who principal))
  (is-some (map-get? refugees who)))

(define-read-only (is-verified (who principal))
  (let ((p (map-get? refugees who)))
    (if (is-some p) (get verified (unwrap-panic p)) false)))

(define-read-only (verification-level-of (who principal))
  (let ((p (map-get? refugees who)))
    (if (is-some p) (get verification-level (unwrap-panic p)) u0)))
