MATCH (n) RETURN labels(n)[0] AS label, count(*) AS count ORDER BY count DESC;
