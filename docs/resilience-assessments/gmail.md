# Service Resilience Scoring: Gmail

This document scores Gmail as a third-party dependency using the five heuristics from the personal resiliency framework. Each heuristic is scored using a traffic light system:
- 🟢 Green: Strong
- 🟡 Yellow: Adequate but could be improved
- 🔴 Red: Weak or absent

The goal is to identify which aspects of your relationship to Gmail are resilient and which need attention.

## Heuristic Scoring

| Heuristic | Score | Notes |
|-----------|-------|-------|
| **Robustness** | 🔴 | Gmail loss means **identity loss** across hundreds of services. Cannot receive password resets, 2FA codes, or account recovery emails. Existing logged-in sessions continue but cannot recover if logged out. |
| **Redundancy** | 🔴 | **No alternative email identity** for most services. Most accounts tied to single Gmail address. No backup email configured for critical services. No email forwarding or backup identity system. |
| **Resourcefulness** | 🟡 | Could create new email and manually migrate accounts, but requires access to each service individually. Some services won't allow email changes without existing email access (catch-22). Password managers help but don't solve identity problem. |
| **Rapidity** | 🔴 | Account recovery depends entirely on Google. Can take **days to weeks** if account locked/suspended. No self-service recovery for identity. Manual migration to new email: 20-40+ hours for all services. |
| **Decoupling** | 🔴 | **Extremely coupled** - Gmail is single point of failure for: All account logins, password resets, 2FA delivery, financial accounts, work/professional identity, government services, healthcare portals, utilities, subscriptions. |

## Current State Analysis

### What Gmail Provides
- **Primary Email Communication**: Personal and professional correspondence
- **Identity Provider**: Login for Google services (Drive, Calendar, YouTube, etc.)
- **Account Recovery Mechanism**: Password reset emails for hundreds of services
- **2FA Delivery**: Email-based two-factor authentication codes
- **Service Authentication**: "Sign in with Google" OAuth identity
- **Professional Identity**: Email address on resume, business cards, professional profiles

### Typical Account Dependencies
Gmail is typically the login/recovery email for:
- **Financial**: Banks, credit cards, investment accounts, PayPal, Stripe
- **Professional**: LinkedIn, job sites, professional associations
- **Government**: IRS, SSA, state services, healthcare.gov
- **Utilities**: Electric, gas, water, internet, phone providers
- **Subscriptions**: Streaming services, SaaS tools, memberships
- **E-commerce**: Amazon, eBay, shopping accounts
- **Social**: Facebook, Twitter, Instagram (often tied via email)
- **Infrastructure**: Domain registrars, cloud providers, hosting

## Risk Scenarios

### High-Impact Scenarios

1. **Account Suspension/Termination**:
   - Google detects "suspicious activity" or ToS violation
   - Account immediately locked
   - Cannot access any Google services
   - Cannot receive emails (password resets fail)
   - All "Sign in with Google" logins stop working
   - **Recovery**: Submit appeals to Google, wait days/weeks, often unsuccessful

2. **Account Compromise & Attacker Lockout**:
   - Attacker gains access, changes password and recovery info
   - You're locked out of your own account
   - Cannot receive recovery emails (attacker controls inbox)
   - Race to recover before attacker causes damage
   - **Recovery**: Google account recovery flow, requires proof of identity

3. **Data Loss (Rare but Possible)**:
   - Google experiences data loss incident
   - Email history deleted
   - Cannot prove account ownership for other services
   - Lose correspondence history needed for disputes/records
   - **Recovery**: No recovery if Google loses data

4. **Country/Region Blocking**:
   - Travel to country where Google services blocked
   - Cannot access Gmail for password resets
   - Cannot complete 2FA for other services
   - **Recovery**: VPN (if legal), wait until return, use backup methods

### Cascade Failure Analysis

```
Gmail Loss
    ↓
Cannot receive password resets
    ↓
Locked out of banking (needs email reset)
    ↓
Cannot pay bills
    ↓
Service disruptions

Gmail Loss
    ↓
Cannot access Google Drive
    ↓
Lose access to documents
    ↓
Work/personal disruption

Gmail Loss
    ↓
"Sign in with Google" fails
    ↓
Locked out of 10+ services
    ↓
Manual recovery for each
```

### Recovery Time Estimates
- **Google account recovery (if locked)**: Days to weeks (not in your control)
- **Manual email migration (partial)**: 20-40 hours for critical services
- **Complete email migration**: 40-100+ hours for all services
- **Professional identity update**: Weeks to months (business cards, websites, networks)

## Improvement Strategies

### Quick Wins (Low Effort, High Impact)

1. **Add Recovery Email (Non-Google)**
   - Set up ProtonMail, Fastmail, or custom domain email
   - Add as recovery email in Google Account settings
   - Add to critical services (banking, finance) as secondary email
   - **Time**: 1-2 hours
   - **Impact**: Provides escape hatch for Google account recovery

2. **Audit Critical Account Email Addresses**
   ```
   Create spreadsheet:
   - Service name
   - Current email (likely Gmail)
   - Has 2FA? (Y/N)
   - Alternative auth method? (phone, authenticator app)
   - Account recovery email set?
   - Priority (Critical/High/Medium/Low)
   ```
   - Identify top 20 critical services
   - Document alternative authentication methods
   - **Time**: 2-3 hours
   - **Impact**: Visibility into risk exposure

3. **Enable Advanced Protection Program**
   - Google's strongest security (hardware keys required)
   - Prevents most account compromises
   - Harder to recover but much harder to hack
   - **Time**: 1 hour (requires hardware security keys)
   - **Impact**: Reduces compromise risk significantly

4. **Set Up Email Forwarding**
   - Forward all Gmail to backup email address
   - Creates real-time backup of incoming mail
   - Backup address can receive resets/2FA even if Gmail locked
   - **Time**: 15 minutes
   - **Impact**: Immediate redundancy for incoming messages

5. **Document "Break Glass" Procedures**
   ```
   IF Gmail access lost:
   1. Attempt Google account recovery at accounts.google.com/recovery
   2. Contact top 5 critical services (list here) via phone
   3. Request email address change with ID verification
   4. Use backup email for new registrations
   5. Update professional contacts (list here)
   ```
   - **Time**: 1 hour
   - **Impact**: Clear action plan reduces panic and downtime

### Medium-Term Improvements

6. **Migrate Critical Services to Custom Domain**
   - Register personal domain (yourname.com)
   - Set up email forwarding to Gmail initially
   - Use domain email for critical services
   - Can redirect to any email provider without changing address
   - **Time**: 4-8 hours initial setup + gradual migration
   - **Impact**: Full control over email identity, provider-agnostic
   - **Example**: you@yourname.com forwards to Gmail, but can change backend

7. **Implement Dual Email Strategy**
   - **Gmail**: Low-risk services, shopping, newsletters
   - **Custom domain or ProtonMail**: Banking, government, healthcare, professional
   - Separates risk and reduces Gmail as single point of failure
   - **Time**: 10-20 hours for migration
   - **Impact**: Halves exposure to Gmail loss

8. **Replace "Sign in with Google" Logins**
   - Audit services using Google OAuth
   - Create native accounts with passwords (stored in Bitwarden)
   - Remove Google as authentication method where possible
   - Decouples identity from Google ecosystem
   - **Time**: 5-10 hours
   - **Impact**: Reduces Google dependency significantly

9. **Set Up Email Archiving**
   - Use imapsync or similar to backup emails locally
   - Archive to personal NAS or external drive
   - Encrypted backup of entire email history
   - Proves account ownership and preserves records
   - **Time**: 2-4 hours setup + automation
   - **Impact**: Data preservation independent of Google

10. **Create Email Continuity Plan**
    - Document all services using Gmail
    - Create staged migration plan (30/60/90 days)
    - Test backup email with low-risk services
    - **Time**: 8-12 hours
    - **Impact**: Clear roadmap to reduce dependency

### Long-Term Strategic Changes

11. **Full Migration to Custom Domain Email**
    - Self-host email (Mailcow, Mail-in-a-Box) OR
    - Use privacy-focused provider (ProtonMail, Fastmail, Migadu)
    - Migrate all services to new domain
    - Use Gmail as backup/forwarding only
    - **Time**: 40-80 hours over 3-6 months
    - **Impact**: Complete independence from Google identity

12. **Implement Zero-Knowledge Email**
    - ProtonMail or Tutanota for critical communications
    - End-to-end encryption
    - Provider cannot access your data
    - More resilient to provider compromise
    - **Time**: 20-40 hours migration
    - **Impact**: Privacy and security improvement

13. **Geographic/Provider Diversification**
    - Primary email: Custom domain on European provider (GDPR protections)
    - Secondary: US-based provider
    - Tertiary: Self-hosted for ultimate control
    - Each can forward/backup the others
    - **Time**: Significant (80+ hours)
    - **Impact**: Maximum resilience

## Recommended Priority Actions

### Immediate (This Week)
1. ✅ **Add recovery email** (ProtonMail/Fastmail) to Google Account
2. ✅ **Enable 2FA with authenticator app** (not just SMS)
3. ✅ **Download Google Takeout** (backup of all data)
4. ✅ **Document top 10 critical accounts** (banking, healthcare, work)

### Short-Term (This Month)
5. ⏳ **Set up email forwarding** to backup address
6. ⏳ **Audit all services** using Gmail login
7. ⏳ **Enable Advanced Protection Program** (order hardware keys first)
8. ⏳ **Add secondary email** to top 20 critical services

### Medium-Term (Next 3 Months)
9. 🔄 **Register custom domain** (yourname.com)
10. 🔄 **Set up custom domain email** (Fastmail, ProtonMail, or self-hosted)
11. 🔄 **Begin gradual migration** (5-10 services per week)
12. 🔄 **Replace Google OAuth logins** with native accounts

### Long-Term (6-12 Months)
13. 🔮 **Complete migration** to custom domain
14. 🔮 **Implement automated email archiving**
15. 🔮 **Test disaster recovery** quarterly
16. 🔮 **Maintain Gmail as backup** only (not primary identity)

## Success Criteria

Your Gmail dependency will be adequately resilient when:
- ✅ Loss of Gmail would not prevent access to critical services (banking, healthcare)
- ✅ Custom domain email exists and is provider-agnostic
- ✅ Email backup system preserves communication history
- ✅ Recovery email and procedures documented and tested
- ✅ "Sign in with Google" replaced with independent auth on critical services
- ✅ Gmail becomes one option among several, not single point of failure

## Cost-Benefit Analysis

### Option 1: Do Nothing
- **Cost**: $0
- **Risk**: Complete dependency on Google
- **RTO if Gmail lost**: Days to weeks (not in your control)

### Option 2: Quick Wins Only
- **Cost**: $0-50 (hardware keys)
- **Time**: 4-6 hours
- **Risk Reduction**: 30-40%
- **RTO**: 24-48 hours with documented procedures

### Option 3: Custom Domain Migration
- **Cost**: $10-20/year (domain) + $3-9/month (email hosting)
- **Time**: 40-80 hours over 6 months
- **Risk Reduction**: 80-90%
- **RTO**: <1 hour (change domain forwarding)

### Option 4: Full Self-Hosting
- **Cost**: $0 (use existing homelab)
- **Time**: 80-120 hours
- **Risk Reduction**: 95%+
- **RTO**: <1 hour
- **Trade-off**: Now you're responsible for email deliverability/security

## Recommended Approach

**Phase 1 (Week 1)**: Quick wins - recovery email, 2FA, backup
**Phase 2 (Month 1)**: Audit and documentation
**Phase 3 (Months 2-3)**: Custom domain setup and testing
**Phase 4 (Months 4-6)**: Gradual migration of critical services
**Phase 5 (Months 7-12)**: Complete migration, maintain Gmail as backup

This staged approach spreads effort over time and provides incremental risk reduction.

## Conclusion

Gmail represents your **highest-risk dependency** due to its role as identity anchor for your digital life. While convenient, this creates catastrophic single-point-of-failure risk. The good news: solutions exist and can be implemented gradually without service disruption.

**Overall Resilience Score: 🔴 Critical Risk**
**Recommended Action: Immediate - Start this week**

**Key Risk**: Identity loss cascades to hundreds of services
**Key Solution**: Custom domain email provides provider-agnostic identity
**Critical Insight**: Email address should be something you control, not something borrowed from Google
