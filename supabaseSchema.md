## Table `_prisma_migrations`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `varchar` | Primary |
| `checksum` | `varchar` |  |
| `finished_at` | `timestamptz` |  Nullable |
| `migration_name` | `varchar` |  |
| `logs` | `text` |  Nullable |
| `rolled_back_at` | `timestamptz` |  Nullable |
| `started_at` | `timestamptz` |  |
| `applied_steps_count` | `int4` |  |

## Table `farms`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `name` | `text` |  |
| `location` | `text` |  Nullable |
| `capacity` | `int4` |  |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `userId` | `text` |  |
| `subscriptionTier` | `SubscriptionTier` |  |
| `master_license_status` | `text` |  Nullable |

## Table `batches`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `status` | `text` |  |
| `arrivalDate` | `timestamp` |  |
| `breedType` | `text` |  |
| `createdAt` | `timestamp` |  |
| `currentCount` | `int4` |  |
| `houseId` | `text` |  |
| `initialCount` | `int4` |  |
| `updatedAt` | `timestamp` |  |
| `userId` | `text` |  |
| `farmId` | `text` |  |
| `batchName` | `text` |  |
| `carriage_inward` | `numeric` |  Nullable |
| `growthTargetOverride` | `text` |  Nullable |
| `growth_target` | `text` |  Nullable |
| `initialCostActual` | `numeric` |  Nullable |
| `initialCostCarriage` | `numeric` |  Nullable |
| `initialCostOther` | `jsonb` |  Nullable |
| `initial_actual_cost` | `numeric` |  Nullable |
| `initial_other_costs` | `jsonb` |  Nullable |
| `isolationCount` | `int4` |  |
| `type` | `LivestockType` |  |
| `local_batch_id` | `int4` |  Nullable |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `daily_feeding_logs`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batch_id` | `text` |  Nullable |
| `feed_type_id` | `text` |  Nullable |
| `amount_consumed` | `numeric` |  |
| `log_date` | `timestamp` |  |
| `user_id` | `text` |  Nullable |
| `farmId` | `text` |  |
| `formulation_id` | `text` |  Nullable |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `health_records`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batch_id` | `text` |  Nullable |
| `record_type` | `varchar` |  Nullable |
| `description` | `text` |  Nullable |
| `record_date` | `date` |  |
| `farmId` | `text` |  |

## Table `users`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `firstname` | `text` |  Nullable |
| `surname` | `text` |  Nullable |
| `email` | `text` |  Nullable |
| `email_verified` | `timestamp` |  Nullable |
| `image` | `text` |  Nullable |
| `role` | `Role` |  |
| `created_at` | `timestamp` |  |
| `updated_at` | `timestamp` |  |
| `name` | `text` |  Nullable |
| `phone_number` | `text` |  Nullable |
| `middle_name` | `text` |  Nullable |
| `password` | `text` |  Nullable |
| `must_change_password` | `bool` |  |
| `is_payment_admin` | `bool` |  |

## Table `accounts`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `user_id` | `text` |  |
| `type` | `text` |  |
| `provider` | `text` |  |
| `provider_account_id` | `text` |  |
| `refresh_token` | `text` |  Nullable |
| `access_token` | `text` |  Nullable |
| `expires_at` | `int4` |  Nullable |
| `token_type` | `text` |  Nullable |
| `scope` | `text` |  Nullable |
| `id_token` | `text` |  Nullable |
| `session_state` | `text` |  Nullable |

## Table `sessions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `session_token` | `text` |  |
| `user_id` | `text` |  |
| `expires` | `timestamp` |  |
| `device_type` | `text` |  Nullable |
| `farm_id` | `text` |  Nullable |
| `login_time` | `timestamp` |  |

## Table `verification_tokens`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `identifier` | `text` |  |
| `token` | `text` |  |
| `expires` | `timestamp` |  |

## Table `houses`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `name` | `text` |  |
| `capacity` | `int4` |  |
| `currentTemperature` | `numeric` |  Nullable |
| `currentHumidity` | `numeric` |  Nullable |
| `userId` | `text` |  |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `isIsolation` | `bool` |  |

## Table `inventory`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `itemName` | `text` |  |
| `stockLevel` | `numeric` |  |
| `unit` | `text` |  |
| `category` | `text` |  Nullable |
| `userId` | `text` |  |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `farmId` | `text` |  |
| `reorderLevel` | `numeric` |  Nullable |
| `costPerUnit` | `numeric` |  Nullable |
| `eggCategoryId` | `text` |  Nullable |
| `supplierId` | `text` |  Nullable |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `egg_production`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batchId` | `text` |  |
| `eggsCollected` | `int4` |  |
| `logDate` | `timestamp` |  |
| `userId` | `text` |  |
| `createdAt` | `timestamp` |  |
| `farmId` | `text` |  |
| `categoryId` | `text` |  Nullable |
| `cratesCollected` | `numeric` |  Nullable |
| `eggsRemaining` | `int4` |  |
| `qualityGrade` | `text` |  Nullable |
| `unusableCount` | `int4` |  |
| `isSorted` | `bool` |  |
| `largeCount` | `int4` |  |
| `mediumCount` | `int4` |  |
| `smallCount` | `int4` |  |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `mortality`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batchId` | `text` |  |
| `count` | `int4` |  |
| `reason` | `text` |  Nullable |
| `logDate` | `timestamp` |  |
| `userId` | `text` |  |
| `createdAt` | `timestamp` |  |
| `category` | `text` |  Nullable |
| `farmId` | `text` |  |
| `sub_category` | `text` |  Nullable |
| `isolation_room_id` | `text` |  Nullable |
| `type` | `HealthEventType` |  |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `sales`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `customerName` | `text` |  Nullable |
| `totalAmount` | `numeric` |  |
| `saleDate` | `timestamp` |  |
| `status` | `text` |  |
| `userId` | `text` |  |
| `createdAt` | `timestamp` |  |
| `farmId` | `text` |  |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `sale_items`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `saleId` | `text` |  |
| `description` | `text` |  |
| `quantity` | `int4` |  |
| `unitPrice` | `numeric` |  |
| `totalPrice` | `numeric` |  |
| `farmId` | `text` |  |

## Table `farm_members`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `userId` | `text` |  |
| `role` | `Role` |  |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |

## Table `invitations`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `email` | `text` |  Nullable |
| `role` | `Role` |  |
| `status` | `text` |  |
| `created_at` | `timestamp` |  |
| `farm_id` | `text` |  |
| `phone_number` | `text` |  Nullable |
| `updated_at` | `timestamp` |  |

## Table `weight_records`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batchId` | `text` |  |
| `averageWeight` | `numeric` |  |
| `logDate` | `timestamp` |  |
| `userId` | `text` |  |
| `farmId` | `text` |  |
| `createdAt` | `timestamp` |  |

## Table `vaccination_schedules`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batchId` | `text` |  |
| `vaccineName` | `text` |  |
| `scheduledDate` | `timestamp` |  |
| `status` | `text` |  |
| `notes` | `text` |  Nullable |
| `farmId` | `text` |  |

## Table `medication_schedules`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `batchId` | `text` |  |
| `medicationName` | `text` |  |
| `scheduledDate` | `timestamp` |  |
| `status` | `text` |  |
| `notes` | `text` |  Nullable |
| `farmId` | `text` |  |

## Table `farm_settings`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `eggRecordReminderTime` | `text` |  Nullable |
| `feedRecordReminderTime` | `text` |  Nullable |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `currency` | `text` |  |
| `growth_target_standard` | `int4` |  Nullable |
| `eggsPerCrate` | `int4` |  |

## Table `audit_logs`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `table_name` | `text` |  |
| `record_id` | `text` |  |
| `attribute_name` | `text` |  |
| `old_value` | `text` |  Nullable |
| `new_value` | `text` |  Nullable |
| `reason` | `text` |  Nullable |
| `user_id` | `text` |  |
| `farm_id` | `text` |  |
| `created_at` | `timestamp` |  |
| `action_type` | `text` |  Nullable |
| `description` | `text` |  Nullable |
| `metadata` | `jsonb` |  Nullable |

## Table `expenses`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `user_id` | `text` |  |
| `amount` | `numeric` |  |
| `category` | `ExpenseCategory` |  |
| `description` | `text` |  Nullable |
| `expense_date` | `timestamp` |  |
| `created_at` | `timestamp` |  |
| `updated_at` | `timestamp` |  |
| `batch_id` | `text` |  Nullable |
| `supplierId` | `text` |  Nullable |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `user_permissions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `user_id` | `text` |  |
| `farm_id` | `text` |  |
| `can_view_finance` | `bool` |  |
| `can_edit_finance` | `bool` |  |
| `can_view_inventory` | `bool` |  |
| `can_edit_inventory` | `bool` |  |
| `can_view_batches` | `bool` |  |
| `can_edit_batches` | `bool` |  |
| `can_view_sales` | `bool` |  |
| `can_edit_sales` | `bool` |  |
| `can_view_eggs` | `bool` |  |
| `can_edit_eggs` | `bool` |  |
| `can_view_feeding` | `bool` |  |
| `can_edit_feeding` | `bool` |  |
| `can_view_houses` | `bool` |  |
| `can_edit_houses` | `bool` |  |
| `can_view_mortality` | `bool` |  |
| `can_edit_mortality` | `bool` |  |
| `can_view_customers` | `bool` |  |
| `can_edit_customers` | `bool` |  |
| `can_view_team` | `bool` |  |
| `can_edit_team` | `bool` |  |

## Table `growth_standards`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `livestockType` | `LivestockType` |  |
| `ageInDays` | `int4` |  |
| `targetWeight` | `numeric` |  |
| `targetFeed` | `numeric` |  Nullable |
| `unit` | `text` |  |
| `createdAt` | `timestamp` |  |

## Table `subscription_plans`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `name` | `text` |  |
| `tier` | `SubscriptionTier` |  |
| `price` | `numeric` |  |
| `currency` | `text` |  |
| `interval` | `text` |  |
| `features` | `jsonb` |  Nullable |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |

## Table `subscriptions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `planId` | `text` |  |
| `status` | `text` |  |
| `startDate` | `timestamp` |  |
| `endDate` | `timestamp` |  Nullable |

## Table `customers`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `name` | `text` |  |
| `phone` | `text` |  Nullable |
| `email` | `text` |  Nullable |
| `address` | `text` |  Nullable |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `balanceOwed` | `numeric` |  |

## Table `orders`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `customerId` | `text` |  Nullable |
| `totalAmount` | `numeric` |  |
| `currency` | `text` |  |
| `status` | `text` |  |
| `discountAmount` | `numeric` |  |
| `created_at` | `timestamp` |  |
| `order_date` | `timestamp` |  |
| `updated_at` | `timestamp` |  |
| `user_id` | `text` |  |
| `is_deleted` | `bool` |  |
| `deleted_at` | `timestamp` |  Nullable |

## Table `order_items`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `orderId` | `text` |  |
| `description` | `text` |  |
| `quantity` | `int4` |  |
| `unitPrice` | `numeric` |  |
| `totalPrice` | `numeric` |  |
| `inventoryId` | `text` |  Nullable |
| `livestockId` | `text` |  Nullable |

## Table `feed_formulations`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `name` | `text` |  |
| `notes` | `text` |  Nullable |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `targetLivestock` | `LivestockType` |  Nullable |
| `type` | `FeedType` |  |
| `stockLevel` | `numeric` |  |

## Table `feed_formulation_ingredients`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `formulationId` | `text` |  |
| `inventoryId` | `text` |  |
| `quantity` | `numeric` |  |
| `unit` | `text` |  |

## Table `suppliers`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `name` | `text` |  |
| `phone` | `text` |  Nullable |
| `email` | `text` |  Nullable |
| `address` | `text` |  Nullable |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |
| `balanceOwed` | `numeric` |  |

## Table `egg_categories`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `name` | `text` |  |
| `description` | `text` |  Nullable |
| `createdAt` | `timestamp` |  |
| `isStockInternal` | `bool` |  |
| `sellingPrice` | `numeric` |  |
| `unitSize` | `int4` |  |
| `updatedAt` | `timestamp` |  |

## Table `insert_logs`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `user_id` | `text` |  |
| `farm_id` | `text` |  |
| `target_table` | `text` |  |
| `record_id` | `text` |  |
| `inserted_at` | `timestamp` |  |

## Table `delete_logs`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `user_id` | `text` |  |
| `farm_id` | `text` |  |
| `table_name` | `text` |  |
| `deleted_data_csv` | `text` |  |
| `deleted_at` | `timestamp` |  |
| `reason` | `text` |  Nullable |

## Table `isolation_rooms`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farmId` | `text` |  |
| `name` | `text` |  |
| `capacity` | `int4` |  |
| `userId` | `text` |  |
| `createdAt` | `timestamp` |  |
| `updatedAt` | `timestamp` |  |

## Table `device_registrations`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `farm_id` | `text` |  |
| `user_id` | `text` |  Nullable |
| `deviceId` | `text` |  Nullable |
| `deviceName` | `text` |  Nullable |
| `deviceType` | `text` |  Nullable |
| `lastSync` | `timestamp` |  |
| `isActive` | `bool` |  |
| `created_at` | `timestamptz` |  |
| `licenseKey` | `text` |  Nullable |
| `license_status` | `text` |  |
| `hardware_id` | `text` |  Nullable |
| `license_expires_at` | `timestamptz` |  Nullable |
| `lastActivationToken` | `text` |  Nullable |
| `lastPaymentAt` | `timestamp` |  Nullable |
| `activatedByAdminId` | `text` |  Nullable |
| `grace_rescue_used_at` | `timestamptz` |  Nullable |
| `activation_key_status` | `text` |  |

## Table `financial_transactions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farm_id` | `text` |  |
| `user_id` | `text` |  |
| `type` | `text` |  |
| `category` | `text` |  |
| `amount` | `numeric` |  |
| `payment_status` | `text` |  |
| `payment_method` | `text` |  |
| `reference_num` | `text` |  Nullable |
| `transaction_date` | `timestamp` |  |
| `description` | `text` |  Nullable |
| `deleted_at` | `timestamp` |  Nullable |
| `created_at` | `timestamp` |  |
| `updated_at` | `timestamp` |  |
| `is_deleted` | `bool` |  |
| `settled_at` | `timestamp` |  Nullable |

## Table `admin_user`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `username` | `text` |  |
| `password_hash` | `text` |  |
| `is_active` | `bool` |  |
| `created_at` | `timestamp` |  |
| `updated_at` | `timestamp` |  |
| `last_login_at` | `timestamp` |  Nullable |

## Table `manual_license_payments`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `farm_id` | `text` |  |
| `device_registration_id` | `uuid` |  |
| `admin_user_id` | `text` |  |
| `hardware_id` | `text` |  |
| `amount` | `numeric` |  |
| `currency` | `text` |  |
| `duration_days` | `int4` |  |
| `target_expiry_date` | `timestamp` |  |
| `payment_mode_note` | `text` |  |
| `activation_token` | `text` |  |
| `created_at` | `timestamp` |  |

## Table `admin_license_renewal_log`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `admin_user_id` | `text` |  |
| `device_registration_id` | `uuid` |  |
| `hardware_id` | `text` |  |
| `duration_months` | `int4` |  |
| `previous_license_status` | `text` |  Nullable |
| `new_license_status` | `text` |  |
| `previous_expires_at` | `timestamptz` |  Nullable |
| `new_expires_at` | `timestamptz` |  |
| `created_at` | `timestamptz` |  |

