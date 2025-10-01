;; device-pool
;; Shared medical equipment financing platform with tokenized ownership,
;; usage-based cost allocation, and automated scheduling coordination

;; constants
(define-constant ERR_UNAUTHORIZED (err u1))
(define-constant ERR_DEVICE_NOT_FOUND (err u2))
(define-constant ERR_INSUFFICIENT_TOKENS (err u3))
(define-constant ERR_INVALID_AMOUNT (err u4))
(define-constant ERR_SLOT_OCCUPIED (err u5))
(define-constant ERR_INVALID_TIME_SLOT (err u6))
(define-constant ERR_DEVICE_ALREADY_EXISTS (err u7))
(define-constant ERR_MAINTENANCE_REQUIRED (err u8))
(define-constant ERR_INSUFFICIENT_BALANCE (err u9))
(define-constant ERR_INVALID_DEVICE_STATUS (err u10))
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_TOKEN_PURCHASE u10)
(define-constant MAX_TOKENS_PER_DEVICE u10000)
(define-constant MAINTENANCE_THRESHOLD u1000) ;; usage hours before maintenance
(define-constant PLATFORM_FEE_RATE u2) ;; 2%

;; data maps and vars
(define-map devices
    { device-id: uint }
    {
        name: (string-ascii 64),
        manufacturer: (string-ascii 32),
        model: (string-ascii 32),
        total-cost: uint,
        total-tokens: uint,
        tokens-sold: uint,
        status: (string-ascii 20),
        location: (string-ascii 64),
        installation-date: uint,
        total-usage-hours: uint,
        maintenance-due: bool,
        revenue-generated: uint
    }
)

(define-map token-ownership
    { device-id: uint, owner: principal }
    {
        tokens-owned: uint,
        purchase-date: uint,
        total-paid: uint,
        usage-hours: uint,
        last-usage: uint
    }
)

(define-map usage-schedule
    { device-id: uint, start-time: uint, end-time: uint }
    {
        facility: principal,
        procedure-type: (string-ascii 32),
        estimated-duration: uint,
        actual-duration: (optional uint),
        cost: uint,
        status: (string-ascii 20)
    }
)

(define-map facility-profiles
    { facility: principal }
    {
        name: (string-ascii 64),
        license-id: (string-ascii 32),
        total-usage-hours: uint,
        total-payments: uint,
        reputation-score: uint,
        active-bookings: uint
    }
)

(define-map maintenance-records
    { device-id: uint, maintenance-id: uint }
    {
        maintenance-type: (string-ascii 32),
        cost: uint,
        provider: principal,
        scheduled-date: uint,
        completed-date: (optional uint),
        description: (string-ascii 128)
    }
)

(define-map cost-allocations
    { device-id: uint, period: uint }
    {
        total-costs: uint,
        maintenance-costs: uint,
        insurance-costs: uint,
        facility-costs: uint,
        allocated: bool
    }
)

(define-data-var next-device-id uint u1)
(define-data-var next-maintenance-id uint u1)
(define-data-var total-devices uint u0)
(define-data-var platform-revenue uint u0)
(define-data-var total-usage-hours uint u0)

;; private functions
(define-private (min (a uint) (b uint))
    (if (< a b) a b)
)

(define-private (max (a uint) (b uint))
    (if (> a b) a b)
)

(define-private (calculate-token-price (device-cost uint) (total-tokens uint))
    (/ device-cost total-tokens)
)

(define-private (calculate-usage-cost (device-id uint) (duration uint))
    (let (
        (device-data (unwrap-panic (map-get? devices { device-id: device-id })))
        (hourly-rate (/ (get total-cost device-data) u8760)) ;; cost per hour over 1 year
    )
    (* hourly-rate duration)
    )
)

(define-private (is-time-slot-available (device-id uint) (start-time uint) (end-time uint))
    (let (
        (existing-booking (map-get? usage-schedule { device-id: device-id, start-time: start-time, end-time: end-time }))
    )
    (is-none existing-booking)
    )
)

(define-private (update-maintenance-status (device-id uint))
    (let (
        (device-data (unwrap-panic (map-get? devices { device-id: device-id })))
        (needs-maintenance (>= (get total-usage-hours device-data) MAINTENANCE_THRESHOLD))
    )
    (map-set devices { device-id: device-id }
        {
            name: (get name device-data),
            manufacturer: (get manufacturer device-data),
            model: (get model device-data),
            total-cost: (get total-cost device-data),
            total-tokens: (get total-tokens device-data),
            tokens-sold: (get tokens-sold device-data),
            status: (get status device-data),
            location: (get location device-data),
            installation-date: (get installation-date device-data),
            total-usage-hours: (get total-usage-hours device-data),
            maintenance-due: needs-maintenance,
            revenue-generated: (get revenue-generated device-data)
        }
    )
    )
)

(define-private (distribute-revenue-to-owners (device-id uint) (revenue uint))
    (let (
        (device-data (unwrap-panic (map-get? devices { device-id: device-id })))
        (total-tokens (get total-tokens device-data))
        (platform-fee (/ (* revenue PLATFORM_FEE_RATE) u100))
        (distributable-revenue (- revenue platform-fee))
    )
    ;; Update platform revenue
    (var-set platform-revenue (+ (var-get platform-revenue) platform-fee))
    
    ;; Update device revenue
    (map-set devices { device-id: device-id }
        {
            name: (get name device-data),
            manufacturer: (get manufacturer device-data),
            model: (get model device-data),
            total-cost: (get total-cost device-data),
            total-tokens: (get total-tokens device-data),
            tokens-sold: (get tokens-sold device-data),
            status: (get status device-data),
            location: (get location device-data),
            installation-date: (get installation-date device-data),
            total-usage-hours: (get total-usage-hours device-data),
            maintenance-due: (get maintenance-due device-data),
            revenue-generated: (+ (get revenue-generated device-data) revenue)
        }
    )
    distributable-revenue
    )
)

;; public functions
(define-public (register-facility (name (string-ascii 64)) (license-id (string-ascii 32)))
    (let (
        (existing-facility (map-get? facility-profiles { facility: tx-sender }))
    )
    (asserts! (is-none existing-facility) ERR_DEVICE_ALREADY_EXISTS)
    
    (map-set facility-profiles { facility: tx-sender }
        {
            name: name,
            license-id: license-id,
            total-usage-hours: u0,
            total-payments: u0,
            reputation-score: u100,
            active-bookings: u0
        }
    )
    (ok true)
    )
)

(define-public (tokenize-device (name (string-ascii 64)) (manufacturer (string-ascii 32)) (model (string-ascii 32)) (total-cost uint) (location (string-ascii 64)) (total-tokens uint))
    (let (
        (device-id (var-get next-device-id))
    )
    (asserts! (and (> total-cost u0) (<= total-tokens MAX_TOKENS_PER_DEVICE)) ERR_INVALID_AMOUNT)
    (asserts! (>= total-tokens u100) ERR_INVALID_AMOUNT)
    
    (map-set devices { device-id: device-id }
        {
            name: name,
            manufacturer: manufacturer,
            model: model,
            total-cost: total-cost,
            total-tokens: total-tokens,
            tokens-sold: u0,
            status: "available",
            location: location,
            installation-date: block-height,
            total-usage-hours: u0,
            maintenance-due: false,
            revenue-generated: u0
        }
    )
    
    (var-set next-device-id (+ device-id u1))
    (var-set total-devices (+ (var-get total-devices) u1))
    
    (ok device-id)
    )
)

(define-public (purchase-tokens (device-id uint) (token-amount uint))
    (let (
        (device-data (unwrap! (map-get? devices { device-id: device-id }) ERR_DEVICE_NOT_FOUND))
        (token-price (calculate-token-price (get total-cost device-data) (get total-tokens device-data)))
        (total-cost (* token-amount token-price))
        (current-ownership (default-to
            { tokens-owned: u0, purchase-date: u0, total-paid: u0, usage-hours: u0, last-usage: u0 }
            (map-get? token-ownership { device-id: device-id, owner: tx-sender })
        ))
        (available-tokens (- (get total-tokens device-data) (get tokens-sold device-data)))
    )
    (asserts! (>= token-amount MIN_TOKEN_PURCHASE) ERR_INVALID_AMOUNT)
    (asserts! (>= available-tokens token-amount) ERR_INSUFFICIENT_TOKENS)
    
    ;; Update token ownership
    (map-set token-ownership { device-id: device-id, owner: tx-sender }
        {
            tokens-owned: (+ (get tokens-owned current-ownership) token-amount),
            purchase-date: block-height,
            total-paid: (+ (get total-paid current-ownership) total-cost),
            usage-hours: (get usage-hours current-ownership),
            last-usage: (get last-usage current-ownership)
        }
    )
    
    ;; Update device tokens sold
    (map-set devices { device-id: device-id }
        {
            name: (get name device-data),
            manufacturer: (get manufacturer device-data),
            model: (get model device-data),
            total-cost: (get total-cost device-data),
            total-tokens: (get total-tokens device-data),
            tokens-sold: (+ (get tokens-sold device-data) token-amount),
            status: (get status device-data),
            location: (get location device-data),
            installation-date: (get installation-date device-data),
            total-usage-hours: (get total-usage-hours device-data),
            maintenance-due: (get maintenance-due device-data),
            revenue-generated: (get revenue-generated device-data)
        }
    )
    
    (ok total-cost)
    )
)

(define-public (schedule-usage (device-id uint) (start-time uint) (end-time uint) (procedure-type (string-ascii 32)))
    (let (
        (device-data (unwrap! (map-get? devices { device-id: device-id }) ERR_DEVICE_NOT_FOUND))
        (facility-data (unwrap! (map-get? facility-profiles { facility: tx-sender }) ERR_UNAUTHORIZED))
        (duration (- end-time start-time))
        (usage-cost (calculate-usage-cost device-id duration))
    )
    (asserts! (> end-time start-time) ERR_INVALID_TIME_SLOT)
    (asserts! (is-eq (get status device-data) "available") ERR_INVALID_DEVICE_STATUS)
    (asserts! (not (get maintenance-due device-data)) ERR_MAINTENANCE_REQUIRED)
    (asserts! (is-time-slot-available device-id start-time end-time) ERR_SLOT_OCCUPIED)
    
    ;; Create usage schedule
    (map-set usage-schedule { device-id: device-id, start-time: start-time, end-time: end-time }
        {
            facility: tx-sender,
            procedure-type: procedure-type,
            estimated-duration: duration,
            actual-duration: none,
            cost: usage-cost,
            status: "scheduled"
        }
    )
    
    ;; Update facility active bookings
    (map-set facility-profiles { facility: tx-sender }
        {
            name: (get name facility-data),
            license-id: (get license-id facility-data),
            total-usage-hours: (get total-usage-hours facility-data),
            total-payments: (get total-payments facility-data),
            reputation-score: (get reputation-score facility-data),
            active-bookings: (+ (get active-bookings facility-data) u1)
        }
    )
    
    (ok usage-cost)
    )
)

(define-public (record-usage (device-id uint) (start-time uint) (end-time uint) (actual-end-time uint) (procedures-completed uint))
    (let (
        (device-data (unwrap! (map-get? devices { device-id: device-id }) ERR_DEVICE_NOT_FOUND))
        (schedule-data (unwrap! (map-get? usage-schedule { device-id: device-id, start-time: start-time, end-time: end-time }) ERR_INVALID_TIME_SLOT))
        (facility-data (unwrap-panic (map-get? facility-profiles { facility: tx-sender })))
        (actual-duration (- actual-end-time start-time))
        (usage-cost (get cost schedule-data))
    )
    (asserts! (is-eq (get facility schedule-data) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status schedule-data) "scheduled") ERR_INVALID_DEVICE_STATUS)
    
    ;; Update usage schedule with actual data
    (map-set usage-schedule { device-id: device-id, start-time: start-time, end-time: end-time }
        {
            facility: (get facility schedule-data),
            procedure-type: (get procedure-type schedule-data),
            estimated-duration: (get estimated-duration schedule-data),
            actual-duration: (some actual-duration),
            cost: usage-cost,
            status: "completed"
        }
    )
    
    ;; Update device usage hours
    (map-set devices { device-id: device-id }
        {
            name: (get name device-data),
            manufacturer: (get manufacturer device-data),
            model: (get model device-data),
            total-cost: (get total-cost device-data),
            total-tokens: (get total-tokens device-data),
            tokens-sold: (get tokens-sold device-data),
            status: (get status device-data),
            location: (get location device-data),
            installation-date: (get installation-date device-data),
            total-usage-hours: (+ (get total-usage-hours device-data) actual-duration),
            maintenance-due: (get maintenance-due device-data),
            revenue-generated: (get revenue-generated device-data)
        }
    )
    
    ;; Update facility usage and payments
    (map-set facility-profiles { facility: tx-sender }
        {
            name: (get name facility-data),
            license-id: (get license-id facility-data),
            total-usage-hours: (+ (get total-usage-hours facility-data) actual-duration),
            total-payments: (+ (get total-payments facility-data) usage-cost),
            reputation-score: (get reputation-score facility-data),
            active-bookings: (- (get active-bookings facility-data) u1)
        }
    )
    
    ;; Update global usage hours
    (var-set total-usage-hours (+ (var-get total-usage-hours) actual-duration))
    
    ;; Check maintenance status
    (update-maintenance-status device-id)
    
    ;; Distribute revenue
    (let ((distributed-revenue (distribute-revenue-to-owners device-id usage-cost)))
        (ok distributed-revenue)
    )
    )
)

(define-public (schedule-maintenance (device-id uint) (maintenance-type (string-ascii 32)) (cost uint) (scheduled-date uint) (description (string-ascii 128)))
    (let (
        (device-data (unwrap! (map-get? devices { device-id: device-id }) ERR_DEVICE_NOT_FOUND))
        (maintenance-id (var-get next-maintenance-id))
    )
    (asserts! (get maintenance-due device-data) ERR_INVALID_DEVICE_STATUS)
    (asserts! (> cost u0) ERR_INVALID_AMOUNT)
    
    (map-set maintenance-records { device-id: device-id, maintenance-id: maintenance-id }
        {
            maintenance-type: maintenance-type,
            cost: cost,
            provider: tx-sender,
            scheduled-date: scheduled-date,
            completed-date: none,
            description: description
        }
    )
    
    ;; Update device status
    (map-set devices { device-id: device-id }
        {
            name: (get name device-data),
            manufacturer: (get manufacturer device-data),
            model: (get model device-data),
            total-cost: (get total-cost device-data),
            total-tokens: (get total-tokens device-data),
            tokens-sold: (get tokens-sold device-data),
            status: "maintenance",
            location: (get location device-data),
            installation-date: (get installation-date device-data),
            total-usage-hours: (get total-usage-hours device-data),
            maintenance-due: false,
            revenue-generated: (get revenue-generated device-data)
        }
    )
    
    (var-set next-maintenance-id (+ maintenance-id u1))
    (ok maintenance-id)
    )
)

;; read-only functions
(define-read-only (get-device-details (device-id uint))
    (map-get? devices { device-id: device-id })
)

(define-read-only (get-token-ownership (device-id uint) (owner principal))
    (map-get? token-ownership { device-id: device-id, owner: owner })
)

(define-read-only (get-usage-schedule (device-id uint) (start-time uint) (end-time uint))
    (map-get? usage-schedule { device-id: device-id, start-time: start-time, end-time: end-time })
)

(define-read-only (get-facility-profile (facility principal))
    (map-get? facility-profiles { facility: facility })
)

(define-read-only (get-maintenance-record (device-id uint) (maintenance-id uint))
    (map-get? maintenance-records { device-id: device-id, maintenance-id: maintenance-id })
)

(define-read-only (get-platform-stats)
    {
        total-devices: (var-get total-devices),
        platform-revenue: (var-get platform-revenue),
        total-usage-hours: (var-get total-usage-hours),
        next-device-id: (var-get next-device-id)
    }
)
