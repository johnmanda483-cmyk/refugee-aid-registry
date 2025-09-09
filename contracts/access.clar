;; title: Aid Access Counters
;; version: 1.0.0
;; summary: Simple independent tracker for access counts by principal
;; description: A minimal contract to demonstrate a second module without
;;              cross-contract calls or traits.

(define-constant ERR-NEGATIVE (err u200))
(define-constant ERR-ZERO (err u201))

(define-map access-counts principal uint)

(define-read-only (get-count (who principal))
  (default-to u0 (map-get? access-counts who)))

(define-public (increment (by uint))
  (let ((n (default-to u0 (map-get? access-counts tx-sender))))
    (asserts! (> by u0) ERR-ZERO)
    (map-set access-counts tx-sender (+ n by))
    (ok (+ n by))))

(define-public (decrement (by uint))
  (let ((n (default-to u0 (map-get? access-counts tx-sender))))
    (asserts! (> by u0) ERR-ZERO)
    (asserts! (>= n by) ERR-NEGATIVE)
    (map-set access-counts tx-sender (- n by))
    (ok (- n by))))
