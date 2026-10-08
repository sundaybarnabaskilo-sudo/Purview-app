/**
 * src/types/cooperative.ts
 *
 * Global domain models for the Cooperative Financial Mobile Application.
 * These types are the shared contract between the Data Layer (Supabase),
 * the Business Logic Layer (services/), and the Presentation Layer (screens/, components/).
 *
 * Conventions:
 * - All monetary values are stored as MinorCurrencyUnit (integer, e.g. kobo/cents)
 *   to avoid floating-point rounding errors in financial calculations.
 * - All timestamps are ISODateTimeString (UTC, as returned by Postgres/Supabase).
 * - All primary/foreign keys are UUID (Supabase `uuid` columns).
 */

// ---------------------------------------------------------------------------
// Shared primitives
// ---------------------------------------------------------------------------

export type UUID = string;
export type ISODateTimeString = string;
/** Integer amount in the smallest currency unit (e.g. kobo, cents). Never a float. */
export type MinorCurrencyUnit = number;

/** Generic wrapper for Supabase/service responses, forcing explicit error handling. */
export type Result<T> =
  | { readonly success: true; readonly data: T }
  | { readonly success: false; readonly error: AppError };

export interface AppError {
  readonly code: string;
  readonly message: string;
  readonly details?: Readonly<Record<string, unknown>>;
}

// ---------------------------------------------------------------------------
// User & Roles (Member vs Super-Admin)
// ---------------------------------------------------------------------------

export enum UserRole {
  MEMBER = "MEMBER",
  SUPER_ADMIN = "SUPER_ADMIN",
}

export enum AdminPermission {
  APPROVE_LOANS = "APPROVE_LOANS",
  MANAGE_MEMBERS = "MANAGE_MEMBERS",
  MANAGE_SHARE_CAPITAL = "MANAGE_SHARE_CAPITAL",
  VIEW_FINANCIAL_REPORTS = "VIEW_FINANCIAL_REPORTS",
  POST_LEDGER_ENTRIES = "POST_LEDGER_ENTRIES",
}

interface BaseUser {
  readonly id: UUID; // matches Supabase auth.users.id
  readonly email: string;
  readonly fullName: string;
  readonly phoneNumber: string;
  readonly memberNumber: string; // cooperative-assigned membership number
  readonly isActive: boolean;
  readonly createdAt: ISODateTimeString;
  readonly updatedAt: ISODateTimeString;
}

export interface MemberUser extends BaseUser {
  readonly role: UserRole.MEMBER;
  readonly branchId: UUID;
  readonly dateJoined: ISODateTimeString;
  readonly nextOfKinName: string | null;
  readonly nextOfKinPhone: string | null;
}

export interface SuperAdminUser extends BaseUser {
  readonly role: UserRole.SUPER_ADMIN;
  readonly permissions: readonly AdminPermission[];
}

/** Discriminated union — switch on `role` to narrow to MemberUser | SuperAdminUser. */
export type CooperativeUser = MemberUser | SuperAdminUser;

export function isSuperAdmin(user: CooperativeUser): user is SuperAdminUser {
  return user.role === UserRole.SUPER_ADMIN;
}

export function hasPermission(
  user: CooperativeUser,
  permission: AdminPermission
): boolean {
  return isSuperAdmin(user) && user.permissions.includes(permission);
}

// ---------------------------------------------------------------------------
// Savings Ledger
// ---------------------------------------------------------------------------

export enum SavingsAccountType {
  REGULAR = "REGULAR",
  FIXED_DEPOSIT = "FIXED_DEPOSIT",
  TARGET_SAVINGS = "TARGET_SAVINGS",
}

export enum SavingsAccountStatus {
  ACTIVE = "ACTIVE",
  DORMANT = "DORMANT",
  CLOSED = "CLOSED",
}

export interface SavingsLedger {
  readonly id: UUID;
  readonly memberId: UUID;
  readonly accountNumber: string;
  readonly accountType: SavingsAccountType;
  readonly status: SavingsAccountStatus;
  readonly balance: MinorCurrencyUnit;
  readonly currency: string; // ISO 4217, e.g. "NGN"
  readonly annualInterestRateBps: number; // basis points, e.g. 500 = 5.00%
  readonly lastTransactionAt: ISODateTimeString | null;
  readonly createdAt: ISODateTimeString;
  readonly updatedAt: ISODateTimeString;
}

// ---------------------------------------------------------------------------
// Share Capital
// ---------------------------------------------------------------------------

export interface ShareCapital {
  readonly id: UUID;
  readonly memberId: UUID;
  readonly totalShares: number;
  readonly shareValue: MinorCurrencyUnit; // value per share
  readonly totalContributed: MinorCurrencyUnit;
  readonly dividendsEarnedToDate: MinorCurrencyUnit;
  readonly lastContributionAt: ISODateTimeString | null;
  readonly createdAt: ISODateTimeString;
  readonly updatedAt: ISODateTimeString;
}

// ---------------------------------------------------------------------------
// Loan Application
// ---------------------------------------------------------------------------

export enum LoanType {
  EMERGENCY = "EMERGENCY",
  DEVELOPMENT = "DEVELOPMENT",
  SCHOOL_FEES = "SCHOOL_FEES",
  ASSET_ACQUISITION = "ASSET_ACQUISITION",
}

export enum LoanStatus {
  PENDING = "PENDING",
  UNDER_REVIEW = "UNDER_REVIEW",
  APPROVED = "APPROVED",
  REJECTED = "REJECTED",
  DISBURSED = "DISBURSED",
  ACTIVE = "ACTIVE",
  DEFAULTED = "DEFAULTED",
  CLOSED = "CLOSED",
}

export interface Guarantor {
  readonly memberId: UUID;
  readonly fullName: string;
  readonly hasApproved: boolean;
  readonly approvedAt: ISODateTimeString | null;
}

export interface LoanApplication {
  readonly id: UUID;
  readonly applicantId: UUID;
  readonly loanType: LoanType;
  readonly status: LoanStatus;
  readonly amountRequested: MinorCurrencyUnit;
  readonly amountApproved: MinorCurrencyUnit | null;
  readonly interestRateBps: number;
  readonly repaymentPeriodMonths: number;
  readonly purpose: string;
  readonly guarantors: readonly Guarantor[];
  readonly approvedBy: UUID | null; // Super-Admin id
  readonly approvedAt: ISODateTimeString | null;
  readonly disbursedAt: ISODateTimeString | null;
  readonly submittedAt: ISODateTimeString;
  readonly updatedAt: ISODateTimeString;
}

// ---------------------------------------------------------------------------
// Transaction History
// ---------------------------------------------------------------------------

export enum TransactionType {
  DEPOSIT = "DEPOSIT",
  WITHDRAWAL = "WITHDRAWAL",
  SHARE_PURCHASE = "SHARE_PURCHASE",
  DIVIDEND_PAYOUT = "DIVIDEND_PAYOUT",
  LOAN_DISBURSEMENT = "LOAN_DISBURSEMENT",
  LOAN_REPAYMENT = "LOAN_REPAYMENT",
  INTEREST_CREDIT = "INTEREST_CREDIT",
  FEE_CHARGE = "FEE_CHARGE",
}

export enum TransactionStatus {
  PENDING = "PENDING",
  COMPLETED = "COMPLETED",
  FAILED = "FAILED",
  REVERSED = "REVERSED",
}

export enum LedgerAccountReference {
  SAVINGS = "SAVINGS",
  SHARE_CAPITAL = "SHARE_CAPITAL",
  LOAN = "LOAN",
}

export interface TransactionHistory {
  readonly id: UUID;
  readonly memberId: UUID;
  readonly type: TransactionType;
  readonly status: TransactionStatus;
  readonly amount: MinorCurrencyUnit;
  readonly balanceAfter: MinorCurrencyUnit;
  readonly referenceAccount: LedgerAccountReference;
  readonly referenceId: UUID; // FK -> SavingsLedger.id | ShareCapital.id | LoanApplication.id
  readonly narration: string;
  readonly processedBy: UUID | null; // admin id; null = self-service/system-generated
  readonly createdAt: ISODateTimeString;
}