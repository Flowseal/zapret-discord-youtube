import numpy as np
import time

n = 2048
A = np.random.rand(n, n) + 1j * np.random.rand(n, n)
B = np.random.rand(n, n) + 1j * np.random.rand(n, n)
C = np.zeros((n, n), dtype=np.complex128)

start = time.time()
for i in range(n):
    for j in range(n):
        for k in range(n):
            C[i, j] += A[i, k] * B[k, j]
end = time.time()

t = end - start
c = 2 * n**3
mflops = c / t * 1e-6

print(f"Время: {t:.2f} сек")
print(f"Производительность: {mflops:.2f} MFLOPS")
