package sqlserverlab;

import com.microsoft.sqlserver.javalangextension.AbstractSqlServerExtensionExecutor;
import com.microsoft.sqlserver.javalangextension.PrimitiveDataset;
import java.sql.Types;
import java.util.LinkedHashMap;

/**
 * Synthetic SQL Server Language Extensions probe owned by SQL_Server_Lab.
 *
 * The probe deliberately performs a real one-row input/output roundtrip and
 * reports the runtime and worker identity. It is not a general-purpose Java
 * execution surface.
 */
public final class SqlServerLabExternalRuntimeProbe extends AbstractSqlServerExtensionExecutor {
    public static final String PROBE_VERSION = "1.0.0";

    public SqlServerLabExternalRuntimeProbe() {
        executorExtensionVersion = SQLSERVER_JAVA_LANG_EXTENSION_V1;
        executorInputDatasetClassName = PrimitiveDataset.class.getName();
        executorOutputDatasetClassName = PrimitiveDataset.class.getName();
    }

    public PrimitiveDataset execute(PrimitiveDataset input, LinkedHashMap<String, Object> params) {
        if (input == null || input.getColumnCount() != 1 || input.getColumnType(0) != Types.INTEGER) {
            throw new IllegalArgumentException("Expected one INTEGER input column");
        }

        int[] values = input.getIntColumn(0);
        if (values == null || values.length != 1 || values[0] != 42) {
            throw new IllegalArgumentException("Expected the single input value 42");
        }

        String evidence = String.join(
            "|",
            "SQLLAB_EXTERNAL",
            "Java",
            PROBE_VERSION,
            System.getProperty("java.version"),
            Integer.toString(values[0]),
            System.getProperty("user.name")
        );

        PrimitiveDataset output = new PrimitiveDataset();
        output.addColumnMetadata(0, "evidence", Types.NVARCHAR, 4000, 0);
        output.addStringColumn(0, new String[] { evidence });
        return output;
    }
}
