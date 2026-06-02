# NudgeLab — Co-Regulation & Digital Nudges for Families

**Flutter · Firebase · Cloud Functions · Firestore · Python · Figma**

A full-stack mobile research platform designed to study and support **parent-child digital co-regulation** through behavioral nudges, longitudinal data collection, and real-time interaction logging.

---

## Overview

NudgeLab investigates how families can develop healthier relationships with screen time through structured digital interventions. Rather than relying on traditional parental controls, the app uses **behavioral nudges** — timely, non-coercive prompts — to encourage co-regulation between parents and children.

The platform serves dual roles: a **participant-facing mobile app** for families enrolled in the study, and a **behavioral data collection system** for longitudinal research analysis.

---

## Features

### Parent App
- Family onboarding and child profile setup
- Daily nudge delivery with configurable timing and frequency
- Response tracking — captures whether nudges were acknowledged, acted on, or dismissed
- Progress dashboard showing co-regulation engagement over time

### Child App
- Age-appropriate UI flows designed for younger users
- Emotional check-ins tied to screen time events
- Notification interactions logged for behavioral analysis

### Backend (Firebase + Cloud Functions)
- **Firebase Cloud Functions** — server-side nudge scheduling, push notification dispatch via FCM, and trigger-based event logging
- **Firestore** — real-time NoSQL database storing participant profiles, nudge logs, and interaction records
- **Firebase Authentication** — secure family account management
- Structured data schema designed for downstream behavioral analytics in Python

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Mobile App | Flutter (iOS + Android) |
| Backend | Firebase Cloud Functions (Node.js) |
| Database | Cloud Firestore |
| Notifications | Firebase Cloud Messaging (FCM) |
| Auth | Firebase Authentication |
| Design | Figma (prototyping + usability testing) |
| Analysis | Python (Pandas, behavioral analytics) |

---

## Project Structure
lib/
├── main.dart                  # App entry point
├── app_router.dart            # Navigation routing
├── firebase_options.dart      # Firebase configuration
├── features/                  # Feature modules (parent, child, onboarding, nudges)
└── services/                  # Firebase service abstractions
functions/                     # Cloud Functions for nudge scheduling & FCM
assets/                        # App assets and images

---

## Research Context

This app was built to support a **longitudinal behavioral study** on parent-child digital co-regulation at Boise State University. The study examines whether structured digital nudges can reduce over-reliance on screen time restrictions and foster self-regulated technology use in family settings.

**Research questions:**
- Do daily behavioral nudges meaningfully change parent-child screen time dynamics?
- Which nudge types (reminder, reflection, activity suggestion) drive the highest engagement?
- How does co-regulation behavior evolve over the study period?

Data collected through the app feeds into Python-based behavioral analytics pipelines for statistical analysis and pattern detection.

---

## Related Publication

Bondada et al. *Soul Support: Designing Hopeful Wearables for Children's Emotional Wellness.* ACM IDC '25, 2025.
