-- Too aggressive hoisting/distribution can lead to a compile error
-- here.
-- ==
-- tags { no_opencl }
-- input { [[1,2],[3,4]] } output { [[1,2],[3,4]] }

entry main [m][n] (xss : [m][n]i32): [n][m]i32 =
  map (\j -> map (\i -> xss[j,i]) (iota m)) (iota n)
