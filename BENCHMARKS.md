Alpacki v3.0.1; 11.07.2026

| Case | alpacki | hpax | hpack_erl | alpacki vs hpax | alpacki vs hpack_erl |
| :--- | :---: | :---: | :---: | :---: | :---: |
| encode small (6h) | **971 ns** | 1019.70 ns | 774.33 ns | 4.8% faster | 25.4% slower |
| encode large (46h) | 16.40 μs | **14.97 μs** | 22.23 μs | 9.6% slower | 26.2% faster |
| decode small (6h) | **0.87 μs** | 1.06 μs | 1.07 μs | 17.9% faster | 18.7% faster |
| decode large (46h) | 8.62 μs | **8.30 μs** | 16.71 μs | 3.9% slower | 48.4% faster |
| resize (46 entries) | **92.52 ns** | 662.95 ns | 3422.34 ns | 86.0% faster | 97.3% faster |