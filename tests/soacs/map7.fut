-- ==
-- input {
--   [[1,2,3], [4,5,6]]
--   [[2,1,3], [4,6,5]]
-- }
-- output {
--   [[3, 3, 6], [8, 11, 11]]
-- }
let main(a1: [][]i32, a2: [][]i32): [][]i32 =
  let b = map (\(row: ([]i32,[]i32)): []i32  ->
                let (x,y) = row in
                map (+) x y) (
              zip a1 a2) in
  b
