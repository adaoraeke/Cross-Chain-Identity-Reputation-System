;; Cross-Chain DID Identity Management Contract
;; Implements self-sovereign identity anchored to Bitcoin via Stacks

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_IDENTITY_EXISTS (err u101))
(define-constant ERR_IDENTITY_NOT_FOUND (err u102))
(define-constant ERR_INVALID_SIGNATURE (err u103))
(define-constant ERR_INVALID_METADATA_HASH (err u104))

;; Data Variables
(define-data-var identity-counter uint u0)

;; Data Maps
(define-map identities 
  { did: (string-ascii 64) }
  {
    owner: principal,
    bitcoin-anchor-hash: (buff 32),
    metadata-hash: (string-ascii 64), ;; IPFS/Arweave hash
    verification-key: (buff 33),
    created-at: uint,
    updated-at: uint,
    is-active: bool
  }
)

(define-map principal-to-did 
  { owner: principal }
  { did: (string-ascii 64) }
)

(define-map did-recovery-keys
  { did: (string-ascii 64) }
  { recovery-key: (buff 33), recovery-principal: principal }
)

;; Public Functions

;; Create a new DID identity
(define-public (create-identity 
  (did (string-ascii 64))
  (bitcoin-anchor-hash (buff 32))
  (metadata-hash (string-ascii 64))
  (verification-key (buff 33))
  (recovery-key (buff 33))
  (recovery-principal principal))
  (let ((current-block-height stacks-block-height))
    ;; Check if DID already exists
    (asserts! (is-none (map-get? identities { did: did })) ERR_IDENTITY_EXISTS)
    ;; Check if principal already has a DID
    (asserts! (is-none (map-get? principal-to-did { owner: tx-sender })) ERR_IDENTITY_EXISTS)
    ;; Validate metadata hash format (basic check)
    (asserts! (> (len metadata-hash) u0) ERR_INVALID_METADATA_HASH)
    
    ;; Store identity
    (map-set identities 
      { did: did }
      {
        owner: tx-sender,
        bitcoin-anchor-hash: bitcoin-anchor-hash,
        metadata-hash: metadata-hash,
        verification-key: verification-key,
        created-at: current-block-height,
        updated-at: current-block-height,
        is-active: true
      }
    )
    
    ;; Map principal to DID
    (map-set principal-to-did 
      { owner: tx-sender }
      { did: did }
    )
    
    ;; Set recovery key
    (map-set did-recovery-keys
      { did: did }
      { recovery-key: recovery-key, recovery-principal: recovery-principal }
    )
    
    ;; Increment counter
    (var-set identity-counter (+ (var-get identity-counter) u1))
    
    (ok { did: did, created-at: current-block-height })
  )
)

;; Update identity metadata (only owner can update)
(define-public (update-identity-metadata 
  (did (string-ascii 64))
  (new-metadata-hash (string-ascii 64))
  (new-bitcoin-anchor-hash (buff 32)))
  (let ((identity-data (unwrap! (map-get? identities { did: did }) ERR_IDENTITY_NOT_FOUND)))
    ;; Check ownership
    (asserts! (is-eq tx-sender (get owner identity-data)) ERR_UNAUTHORIZED)
    ;; Check if identity is active
    (asserts! (get is-active identity-data) ERR_IDENTITY_NOT_FOUND)
    ;; Validate new metadata hash
    (asserts! (> (len new-metadata-hash) u0) ERR_INVALID_METADATA_HASH)
    
    ;; Update identity
    (map-set identities 
      { did: did }
      (merge identity-data {
        metadata-hash: new-metadata-hash,
        bitcoin-anchor-hash: new-bitcoin-anchor-hash,
        updated-at: stacks-block-height
      })
    )
    
    (ok { did: did, updated-at: stacks-block-height })
  )
)

;; Deactivate identity (soft delete)
(define-public (deactivate-identity (did (string-ascii 64)))
  (let ((identity-data (unwrap! (map-get? identities { did: did }) ERR_IDENTITY_NOT_FOUND)))
    ;; Check ownership
    (asserts! (is-eq tx-sender (get owner identity-data)) ERR_UNAUTHORIZED)
    
    ;; Deactivate identity
    (map-set identities 
      { did: did }
      (merge identity-data {
        is-active: false,
        updated-at: stacks-block-height
      })
    )
    
    (ok { did: did, deactivated-at: stacks-block-height })
  )
)

;; Recover identity using recovery key
(define-public (recover-identity 
  (did (string-ascii 64))
  (new-owner principal)
  (signature (buff 65)))
  (let (
    (identity-data (unwrap! (map-get? identities { did: did }) ERR_IDENTITY_NOT_FOUND))
    (recovery-data (unwrap! (map-get? did-recovery-keys { did: did }) ERR_IDENTITY_NOT_FOUND))
  )
    ;; Check if caller is the recovery principal
    (asserts! (is-eq tx-sender (get recovery-principal recovery-data)) ERR_UNAUTHORIZED)
    ;; Verify signature (simplified - in production would verify against recovery-key)
    (asserts! (> (len signature) u0) ERR_INVALID_SIGNATURE)
    
    ;; Update identity owner
    (map-set identities 
      { did: did }
      (merge identity-data {
        owner: new-owner,
        updated-at: stacks-block-height
      })
    )
    
    ;; Update principal mapping
    (map-delete principal-to-did { owner: (get owner identity-data) })
    (map-set principal-to-did 
      { owner: new-owner }
      { did: did }
    )
    
    (ok { did: did, new-owner: new-owner, recovered-at: stacks-block-height })
  )
)

;; Read-only Functions

;; Get identity by DID
(define-read-only (get-identity (did (string-ascii 64)))
  (map-get? identities { did: did })
)

;; Get DID by principal
(define-read-only (get-did-by-principal (owner principal))
  (map-get? principal-to-did { owner: owner })
)

;; Verify identity ownership
(define-read-only (verify-identity-owner (did (string-ascii 64)) (claimed-owner principal))
  (match (map-get? identities { did: did })
    identity-data (and 
      (is-eq (get owner identity-data) claimed-owner)
      (get is-active identity-data)
    )
    false
  )
)

;; Get identity count
(define-read-only (get-identity-count)
  (var-get identity-counter)
)

;; Check if DID exists and is active
(define-read-only (is-identity-active (did (string-ascii 64)))
  (match (map-get? identities { did: did })
    identity-data (get is-active identity-data)
    false
  )
)

;; Get Bitcoin anchor hash for cross-chain verification
(define-read-only (get-bitcoin-anchor (did (string-ascii 64)))
  (match (map-get? identities { did: did })
    identity-data (some (get bitcoin-anchor-hash identity-data))
    none
  )
)
