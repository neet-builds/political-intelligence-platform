# Data Warehouse Schema Design (Star Schema)

## Fact Tables
* **fact_election_results:** voter_turnout, vote_count, margin_of_victory.
* **fact_news_sentiment:** article_id, sentiment_score, magnitude, publication_date.
* **fact_politician_mentions:** mention_count, source_id, date_id.

## Dimension Tables
* **dim_politicians:** name, party_affiliation, age, constituency.
* **dim_parties:** party_name, ideology, founding_year.
* **dim_states:** state_name, region, total_seats.
* **dim_dates:** day, month, year, election_cycle.
